import Foundation
import Darwin

/// A Unix-domain socket server for one-line requests: each connection sends one
/// newline-terminated line and gets `handler`'s reply plus a newline back, then is closed.
/// The bridge socket (`BridgeSocketServer`) is this with the MCP envelope as the handler.
///
/// Only this user's processes get an answer, and none of them can stall it:
/// - the socket file is `0600` from before it accepts anything (chmod between bind and listen);
/// - a peer whose uid (`getpeereid`) is not `allowedUID` is closed unanswered;
/// - each connection is served on a concurrent queue with read/write timeouts, so a client
///   that connects and sends nothing holds one slot for `ioTimeout`, never the server;
/// - a line longer than `maxLineBytes` is closed unanswered;
/// - past `maxConnections` in flight, a new connection is closed unanswered.
///
/// `handler` runs on the connection's background queue; a handler that needs the main actor
/// hops there itself.
public final class LineSocketServer: @unchecked Sendable {
    public let path: String
    private let handler: @Sendable (Data) -> Data
    private let maxLineBytes: Int
    private let ioTimeout: TimeInterval
    private let maxConnections: Int
    private let allowedUID: uid_t

    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var active = 0
    private let acceptQueue = DispatchQueue(label: "admiral.line-socket.accept", qos: .utility)
    private let connectionQueue = DispatchQueue(label: "admiral.line-socket.conn", qos: .utility,
                                                attributes: .concurrent)

    public init(path: String, maxLineBytes: Int = 1 << 20, ioTimeout: TimeInterval = 5,
                maxConnections: Int = 32, allowedUID: uid_t = getuid(),
                handler: @escaping @Sendable (Data) -> Data) {
        self.path = path
        self.maxLineBytes = maxLineBytes
        self.ioTimeout = ioTimeout
        self.maxConnections = maxConnections
        self.allowedUID = allowedUID
        self.handler = handler
    }

    deinit { stop() }

    /// Connections being served right now (tests wait on it).
    public var activeConnections: Int { lock.lock(); defer { lock.unlock() }; return active }

    /// Bind and listen. False when the socket could not be set up (the path is too long for
    /// `sockaddr_un`, bind failed, or the file could not be made `0600`).
    @discardableResult
    public func start() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard listenFD < 0 else { return true }
        unlink(path)  // a stale socket file would make bind() fail
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        // Close-on-exec: the listener must not leak into every spawned session.
        SocketFD.setCloseOnExec(fd)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString)  // NUL-terminated
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            pathBytes.withUnsafeBytes { src in
                dst.copyMemory(from: UnsafeRawBufferPointer(start: src.baseAddress, count: src.count))
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        // 0600 before listen(): until then nobody can connect, so there is no window in which
        // the file is reachable with the umask's looser mode.
        guard bound == 0, chmod(path, 0o600) == 0 else { close(fd); unlink(path); return false }
        // Non-blocking, so the read source drives accept() and stop() frees the socket at once.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        guard listen(fd, 16) == 0 else { close(fd); unlink(path); return false }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptPending(fd) }
        source.setCancelHandler { close(fd) }
        listenFD = fd
        acceptSource = source
        source.resume()
        return true
    }

    public func stop() {
        lock.lock()
        let source = acceptSource
        let wasListening = listenFD >= 0
        acceptSource = nil
        listenFD = -1
        lock.unlock()
        source?.cancel()  // the cancel handler closes the listen fd
        if wasListening { unlink(path) }
    }

    /// Drain every connection this readiness edge covers; EAGAIN ends the batch.
    private func acceptPending(_ fd: Int32) {
        while true {
            let conn = accept(fd, nil, nil)
            if conn < 0 { return }
            SocketFD.setCloseOnExec(conn)
            guard admit(conn) else { close(conn); continue }
            connectionQueue.async { [self] in
                defer { finish() }
                serve(conn)
            }
        }
    }

    /// The peer is this user and there is a free slot (taken here, released by `finish`).
    private func admit(_ conn: Int32) -> Bool {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(conn, &uid, &gid) == 0, uid == allowedUID else { return false }
        lock.lock(); defer { lock.unlock() }
        guard active < maxConnections else { return false }
        active += 1
        return true
    }

    private func finish() {
        lock.lock(); active -= 1; lock.unlock()
    }

    private func serve(_ conn: Int32) {
        defer { close(conn) }
        // accept() inherits O_NONBLOCK from the listener; the timeouts below need blocking I/O.
        _ = fcntl(conn, F_SETFL, fcntl(conn, F_GETFL, 0) & ~O_NONBLOCK)
        var tv = timeval(tv_sec: Int(ioTimeout),
                         tv_usec: Int32((ioTimeout - floor(ioTimeout)) * 1_000_000))
        setsockopt(conn, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(conn, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(conn, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        guard let line = readLine(conn), !line.isEmpty else { return }
        var out = handler(line)
        out.append(0x0A)
        _ = Self.writeAll(conn, out)
    }

    /// The bytes before the first newline; nil on EOF, a timeout, or a line over the cap.
    private func readLine(_ conn: Int32) -> Data? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(conn, &chunk, chunk.count)
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return nil }
            if let newline = chunk[0..<n].firstIndex(of: 0x0A) {
                buffer.append(contentsOf: chunk[0..<newline])
                return buffer.count <= maxLineBytes ? buffer : nil
            }
            buffer.append(contentsOf: chunk[0..<n])
            if buffer.count > maxLineBytes { return nil }
        }
    }

    /// Write every byte, looping over partial writes. False once the peer is gone or stalls
    /// past the send timeout. Internal so the client-tool socket can share it; that socket
    /// must not be this server (a park cannot hold one of these connection slots).
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Bool in
            guard var ptr = buffer.baseAddress else { return true }
            var remaining = buffer.count
            while remaining > 0 {
                let n = write(fd, ptr, remaining)
                if n > 0 {
                    ptr = ptr.advanced(by: n)
                    remaining -= n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }
}
