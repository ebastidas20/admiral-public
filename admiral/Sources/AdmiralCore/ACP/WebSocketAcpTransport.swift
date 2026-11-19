import Foundation

/// Connects to an agent that already serves ACP over a WebSocket (`ws://host:port/acp`, the ACP
/// SDK's WebSocket transport): one JSON-RPC message per text frame, both ways. Nothing is
/// launched, so there is no stderr; the log gets the connection's open, failure and close.
/// A failure line is written without the `acp:` prefix so `AcpLog.lastAgentLine` reports it as
/// the reason a tab or a connection test failed.
public final class WebSocketAcpTransport: AcpTransport, @unchecked Sendable {
    public let lines: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    private let logURL: URL
    private let lock = NSLock()
    private var closed = false

    /// A frame bigger than this fails the connection (a `session/load` replay can be large).
    static let maximumMessageSize = 64 * 1024 * 1024

    public init(url text: String, logURL: URL) throws {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard AcpAgentConfig.isWebSocketURL(trimmed), let url = URL(string: trimmed) else {
            throw AcpTransportError(description: AcpAgentConfig.webSocketURLInvalid)
        }
        self.logURL = logURL
        var cont: AsyncStream<String>.Continuation!
        lines = AsyncStream { cont = $0 }
        continuation = cont
        session = URLSession(configuration: .ephemeral)
        task = session.webSocketTask(with: url)
        task.maximumMessageSize = Self.maximumMessageSize
        AcpLog.append("acp: connecting to \(trimmed)", to: logURL)
        task.resume()
        receiveNext()
    }

    deinit { session.invalidateAndCancel() }

    private func receiveNext() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(.string(text)):
                continuation.yield(text)
            case let .success(.data(data)):
                continuation.yield(String(decoding: data, as: UTF8.self))
            case let .failure(error):
                finish(error: isClosed ? nil : error)
                return
            @unknown default:
                break
            }
            receiveNext()
        }
    }

    private var isClosed: Bool { lock.withLock { closed } }

    public func send(line: String) throws {
        try lock.withLock {
            guard !closed else { throw AcpTransportError(description: "transport closed") }
        }
        task.send(.string(line)) { [weak self] error in
            guard let self, let error, !isClosed else { return }
            finish(error: error)
        }
    }

    public func terminate() {
        guard markClosed() else { return }
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
        AcpLog.append("acp: websocket closed", to: logURL)
        continuation.finish()
    }

    /// The connection ended on its own (the agent closed it, or the network failed).
    private func finish(error: Error?) {
        guard markClosed() else { return }
        if let error {
            AcpLog.append("websocket: \(Self.describe(error, closeCode: task.closeCode))", to: logURL)
        } else {
            AcpLog.append("acp: websocket closed by the agent", to: logURL)
        }
        session.invalidateAndCancel()
        continuation.finish()
    }

    /// True exactly once: the caller that gets it does the closing.
    private func markClosed() -> Bool {
        lock.withLock {
            defer { closed = true }
            return !closed
        }
    }

    private static func describe(_ error: Error, closeCode: URLSessionWebSocketTask.CloseCode) -> String {
        let base = (error as NSError).localizedDescription
        return closeCode == .invalid ? base : "\(base) (close code \(closeCode.rawValue))"
    }
}
