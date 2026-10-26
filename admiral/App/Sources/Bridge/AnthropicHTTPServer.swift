// admiral/App/Sources/Bridge/AnthropicHTTPServer.swift
import Foundation
import Darwin
import AdmiralCore

/// Serves the Anthropic-compatible chat API **and** operator MCP over the same
/// loopback TCP port (default 4141). Paths:
/// - `POST /v1/messages` → Anthropic chat
/// - `POST /mcp` → operator MCP
/// - `GET /sessions/<callsign>/events` → live SSE feed of one session
/// No route requires an API token. Browser-originated requests are still refused (the
/// endpoints check that).
///
/// Mirrors `BridgeSocketServer`: POSIX listener, per-connection blocking reads on a
/// background queue, endpoint work on the main actor.
@MainActor
final class AnthropicHTTPServer {
    private let endpoint: AnthropicEndpoint
    private let mcpEndpoint: OperatorMCPEndpoint?
    private let eventsEndpoint: SessionEventsEndpoint?
    private(set) var port: UInt16 = 0
    private var listenFD: Int32 = -1
    /// Drives `accept()` on a non-blocking listen socket. Cancelling it (in `stop()`)
    /// closes the socket via the cancel handler and frees the port immediately — a
    /// thread parked in a blocking `accept()` would keep the socket, and the port, alive.
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "admiral.anthropic.http", qos: .utility, attributes: .concurrent)
    /// At most 32 connections in flight (a long SSE stream holds one).
    private nonisolated let limiter = ConnectionLimiter(limit: 32)

    init(endpoint: AnthropicEndpoint, mcpEndpoint: OperatorMCPEndpoint? = nil,
         eventsEndpoint: SessionEventsEndpoint? = nil) {
        self.endpoint = endpoint
        self.mcpEndpoint = mcpEndpoint
        self.eventsEndpoint = eventsEndpoint
    }

    deinit {
        acceptSource?.cancel()  // cancel handler owns the listen-fd close
        if acceptSource == nil, listenFD >= 0 { close(listenFD) }
    }

    /// Bind 127.0.0.1:preferredPort, falling back to an ephemeral port; returns the
    /// bound port, or nil when even the fallback failed.
    func start(preferredPort: UInt16 = 4141) -> UInt16? {
        guard listenFD < 0 else { return port }  // already listening — idempotent
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        // Close-on-exec: a claude session Admiral spawns must NOT inherit this listen socket,
        // or the port stays bound after stop() (only the last holder frees it) and a toggled-off
        // server can't reclaim :4141.
        SocketFD.setCloseOnExec(fd)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        func bindTo(_ port: UInt16) -> Bool {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr = in_addr(s_addr: UInt32(INADDR_LOOPBACK).bigEndian)
            let len = socklen_t(MemoryLayout<sockaddr_in>.size)
            return withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) == 0 }
            }
        }
        // A stop()/start() restart (port change, Settings toggle) can race the previous listener's
        // asynchronous close: give the preferred port a short grace period before conceding to an
        // ephemeral port (this race is how the server once ended up on a random port).
        var boundPreferred = bindTo(preferredPort)
        var tries = 0
        while !boundPreferred, preferredPort != 0, errno == EADDRINUSE, tries < 20 {
            usleep(50_000); tries += 1
            boundPreferred = bindTo(preferredPort)
        }
        guard boundPreferred || bindTo(0) else { close(fd); return nil }

        // Read back the actually-bound port (matters for the ephemeral fallback).
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let gotName = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard gotName == 0 else { close(fd); return nil }
        // Non-blocking, so the read source drives accept() without ever parking a thread
        // in a blocking accept() — that's what lets stop() release the port promptly.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        guard listen(fd, 16) == 0 else { close(fd); return nil }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            // Drain every connection this readiness edge covers; EAGAIN ends the batch.
            while true {
                let conn = accept(fd, nil, nil)
                if conn < 0 { break }
                SocketFD.setCloseOnExec(conn)  // an in-flight request fd must not leak into a spawned session
                var noSigPipe: Int32 = 1
                setsockopt(conn, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
                // On BSD/macOS accept() inherits O_NONBLOCK from the non-blocking listen
                // socket. handleConnection's read loop is blocking-by-design, so clear it —
                // otherwise a request body that lands in a later TCP segment (every real
                // SDK/httpx client sends head then body separately) reads as EAGAIN(-1),
                // which the loop treats as EOF and closes the socket with no response.
                _ = fcntl(conn, F_SETFL, fcntl(conn, F_GETFL, 0) & ~O_NONBLOCK)
                // Past the cap a connection is closed unanswered; each admitted one gives its
                // slot back when it closes (handleConnection).
                guard let self, self.limiter.acquire() else { close(conn); continue }
                self.queue.async { self.handleConnection(conn) }
            }
        }
        source.setCancelHandler { [weak self] in
            close(fd)  // closes the listen socket → frees the port
            self?.closed.signal()
        }
        listenFD = fd
        port = UInt16(bigEndian: bound.sin_port)
        acceptSource = source
        source.resume()
        return port
    }

    /// Signalled by the accept source's cancel handler once the listen fd is really closed.
    private let closed = DispatchSemaphore(value: 0)

    func stop() {
        let hadSource = acceptSource != nil
        acceptSource?.cancel()  // cancel handler closes the listen fd, releasing the port
        // Wait (briefly) for the close so an immediate start() can rebind the same port.
        if hadSource { _ = closed.wait(timeout: .now() + 1) }
        acceptSource = nil
        listenFD = -1
        port = 0
    }

    /// Read until a full HTTP request has arrived, then route: `/mcp` → operator MCP,
    /// everything else → Anthropic chat endpoint.
    ///
    /// The read (and every later write) is bounded by `HTTPWire.ioTimeout`. The writes run on
    /// the main actor, so a client that stops reading can block it for up to that long per
    /// write — the bound, not zero, is what this buys for a long SSE stream.
    private nonisolated func handleConnection(_ conn: Int32) {
        let limiter = self.limiter
        guard let request = HTTPWire.readRequest(from: conn) else {
            close(conn); limiter.release(); return
        }
        Task { @MainActor [endpoint, mcpEndpoint, eventsEndpoint] in
            defer { close(conn); limiter.release() }
            if let mcpEndpoint, OperatorMCPEndpoint.isMCPPath(request.path) {
                Self.writeAll(conn, mcpEndpoint.handle(request))
            } else if let eventsEndpoint, SessionEventsEndpoint.callsign(inPath: request.path) != nil {
                // Long-lived: runs until the client hangs up (a failed write) or the tab closes.
                await eventsEndpoint.handle(request) { Self.writeAll(conn, $0) }
            } else {
                await endpoint.handle(request) { data in
                    Self.writeAll(conn, data)
                }
            }
        }
    }

    /// Write every byte of `data`, looping over partial writes. A single `write()` can return
    /// fewer bytes than requested once the body outgrows the socket send buffer (large file
    /// dumps, big replies) or under backpressure — ignoring that would truncate the response
    /// and leave clients parsing half a JSON document. `SO_NOSIGPIPE` is set on the socket, so
    /// a peer that disconnects mid-write yields an error return here rather than signalling us.
    /// Returns false once the peer is gone — how a long-lived SSE stream learns to stop.
    @discardableResult
    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Bool in
            guard var ptr = buffer.baseAddress else { return true }
            var remaining = buffer.count
            while remaining > 0 {
                let n = write(fd, ptr, remaining)
                if n > 0 {
                    ptr = ptr.advanced(by: n)
                    remaining -= n
                } else if n < 0 && errno == EINTR {
                    continue          // interrupted before any byte moved — retry
                } else {
                    return false      // EPIPE / hard error — peer gone, stop
                }
            }
            return true
        }
    }
}
