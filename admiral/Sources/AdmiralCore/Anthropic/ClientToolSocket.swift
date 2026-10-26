import Foundation
import Darwin

/// Broker socket for the `client` MCP process.
///
/// Not `LineSocketServer` and not the bridge socket. `LineSocketServer` answers one
/// line per connection and holds that connection's slot until the handler returns, with
/// a short read timeout and a 32-connection cap. A park lasts for the whole tool round
/// trip, and several parks in one assistant message have to be registered together.
/// This server keeps one long-lived connection per MCP process (one per API tool tab).
/// Its read loop registers each `tools/call` and keeps reading; the wait is a
/// suspended task, so a second park is visible before the first one returns.
public final class ClientToolSocketServer: @unchecked Sendable {
    public let path: String
    private let broker: ClientToolBroker
    private let maxLineBytes: Int
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [Int32] = []
    private let acceptQueue = DispatchQueue(label: "admiral.client-tool.accept", qos: .userInitiated)
    private let connectionQueue = DispatchQueue(label: "admiral.client-tool.conn", qos: .userInitiated,
                                                attributes: .concurrent)

    public init(path: String, broker: ClientToolBroker, maxLineBytes: Int = 4 << 20) {
        self.path = path
        self.broker = broker
        self.maxLineBytes = maxLineBytes
    }

    deinit { stop() }

    /// `~/Library/Application Support/Admiral/client-tools.sock`, beside the bridge socket.
    public static var defaultPath: String {
        AdmiralPaths.defaultSupportDir.appendingPathComponent("client-tools.sock").path
    }

    @discardableResult
    public func start() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard listenFD < 0 else { return true }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        SocketFD.setCloseOnExec(fd)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString)
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
        guard bound == 0, chmod(path, 0o600) == 0 else { close(fd); unlink(path); return false }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        guard listen(fd, 64) == 0 else { close(fd); unlink(path); return false }
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
        let fds = connections
        let wasListening = listenFD >= 0
        acceptSource = nil
        listenFD = -1
        connections = []
        lock.unlock()
        source?.cancel()
        if wasListening { unlink(path) }
        // Unblock each read loop. The loop closes the fd; shutting down is enough.
        for fd in fds { _ = shutdown(fd, SHUT_RDWR) }
    }

    private func acceptPending(_ fd: Int32) {
        while true {
            let conn = accept(fd, nil, nil)
            if conn < 0 { return }
            SocketFD.setCloseOnExec(conn)
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(conn, &uid, &gid) == 0, uid == getuid() else { close(conn); continue }
            lock.lock()
            connections.append(conn)
            lock.unlock()
            connectionQueue.async { [weak self] in
                self?.serve(conn)
            }
        }
    }

    private func serve(_ conn: Int32) {
        defer {
            lock.lock()
            connections.removeAll { $0 == conn }
            lock.unlock()
            close(conn)
        }
        _ = fcntl(conn, F_SETFL, fcntl(conn, F_GETFL, 0) & ~O_NONBLOCK)
        var one: Int32 = 1
        setsockopt(conn, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let writeLock = NSLock()
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        var parked: [UUID] = []
        defer {
            // The MCP process went away. A park this connection registered that nobody
            // has fulfilled yet must not leave `wait` suspended.
            for id in parked { broker.failIfWaiting(id, message: "client tool broker disconnected") }
        }
        while true {
            let n = read(conn, &chunk, chunk.count)
            if n < 0 { if errno == EINTR { continue }; break }
            if n == 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            if buffer.count > maxLineBytes { break }
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                if let id = handle(line, conn: conn, writeLock: writeLock) { parked.append(id) }
            }
        }
    }

    @discardableResult
    private func handle(_ line: Data, conn: Int32, writeLock: NSLock) -> UUID? {
        guard !line.isEmpty,
              let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let id = obj["id"] as? String else { return nil }
        guard let name = obj["name"] as? String, !name.isEmpty else {
            write(conn, writeLock, reply(id: id, result: .text("tools/call requires a name", isError: true)))
            return nil
        }
        let token = obj["token"] as? String ?? ""
        var arguments = obj["arguments"].map(ClientToolMCP.jsonValue(from:)) ?? .object([:])
        if arguments == .null { arguments = .object([:]) }
        let parkID = broker.register(token: token, name: name, arguments: arguments)
        Task { [broker] in
            let result = await broker.wait(parkID)
            self.write(conn, writeLock, self.reply(id: id, result: result))
        }
        return parkID
    }

    private func reply(id: String, result: ClientToolResult) -> Data {
        let object: [String: Any] = [
            "id": id,
            "isError": result.isError,
            "content": AnthropicWire.foundationObject(result.content),
        ]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    private func write(_ conn: Int32, _ writeLock: NSLock, _ data: Data) {
        writeLock.lock(); defer { writeLock.unlock() }
        var line = data
        line.append(0x0A)
        _ = LineSocketServer.writeAll(conn, line)
    }
}

/// Multiplexing client for `ClientToolSocketServer`. `park` sends one line and waits
/// for the matching id; other parks on the same connection proceed at the same time.
public final class ClientToolSocketClient: @unchecked Sendable {
    private let path: String
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var waiters: [String: CheckedContinuation<ClientToolResult, Never>] = [:]
    private var early: [String: ClientToolResult] = [:]
    private let writeLock = NSLock()
    private var readerStarted = false

    public init(path: String) { self.path = path }

    public var isConnected: Bool { lock.lock(); defer { lock.unlock() }; return fd >= 0 }

    @discardableResult
    public func connect() -> Bool {
        lock.lock()
        if fd >= 0 { lock.unlock(); return true }
        lock.unlock()
        let conn = socket(AF_UNIX, SOCK_STREAM, 0)
        guard conn >= 0 else { return false }
        SocketFD.setCloseOnExec(conn)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { Darwin.close(conn); return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            pathBytes.withUnsafeBytes { src in
                dst.copyMemory(from: UnsafeRawBufferPointer(start: src.baseAddress, count: src.count))
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(conn, $0, len) == 0 }
        }
        guard ok else { Darwin.close(conn); return false }
        var one: Int32 = 1
        setsockopt(conn, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        lock.lock()
        fd = conn
        let startReader = !readerStarted
        readerStarted = true
        lock.unlock()
        if startReader {
            Thread.detachNewThread { [weak self] in self?.readLoop() }
        }
        return true
    }

    public func close() {
        lock.lock()
        let conn = fd
        fd = -1
        let pending = waiters
        waiters = [:]
        lock.unlock()
        if conn >= 0 { _ = shutdown(conn, SHUT_RDWR); Darwin.close(conn) }
        for (_, waiter) in pending {
            waiter.resume(returning: .text("client tool broker connection closed", isError: true))
        }
    }

    public func park(token: String, name: String, arguments: JSONValue) async -> ClientToolResult {
        let id = UUID().uuidString
        let object: [String: Any] = [
            "id": id, "token": token, "name": name,
            "arguments": AnthropicWire.foundationObject(arguments),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            return .text("could not encode client tool call", isError: true)
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<ClientToolResult, Never>) in
            lock.lock()
            guard fd >= 0 else {
                lock.unlock()
                cont.resume(returning: .text("Admiral client tool broker is not connected", isError: true))
                return
            }
            if let result = early.removeValue(forKey: id) {
                lock.unlock()
                cont.resume(returning: result)
                return
            }
            waiters[id] = cont
            let conn = fd
            lock.unlock()
            writeLock.lock()
            var line = data
            line.append(0x0A)
            let wrote = LineSocketServer.writeAll(conn, line)
            writeLock.unlock()
            if !wrote {
                lock.lock()
                let waiter = waiters.removeValue(forKey: id)
                lock.unlock()
                waiter?.resume(returning: .text("client tool broker write failed", isError: true))
            }
        }
    }

    private func readLoop() {
        lock.lock()
        let conn = fd
        lock.unlock()
        guard conn >= 0 else { return }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = read(conn, &chunk, chunk.count)
            if n < 0 { if errno == EINTR { continue }; break }
            if n == 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                deliver(line)
            }
        }
    }

    private func deliver(_ line: Data) {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let id = obj["id"] as? String else { return }
        let isError = obj["isError"] as? Bool ?? false
        let content = obj["content"].map(ClientToolMCP.jsonValue(from:)) ?? .array([])
        let result = ClientToolResult(isError: isError, content: content)
        lock.lock()
        let waiter = waiters.removeValue(forKey: id)
        if waiter == nil { early[id] = result }
        lock.unlock()
        waiter?.resume(returning: result)
    }
}
