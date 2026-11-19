import Foundation
@testable import AdmiralCore

/// In-memory `AcpTransport`: tests `feed` agent stdout lines and read what the client `sent`.
final class FakeAcpTransport: AcpTransport, @unchecked Sendable {
    let lines: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let lock = NSLock()
    private var _sent: [String] = []
    private var _terminated = false

    init() {
        var c: AsyncStream<String>.Continuation!
        lines = AsyncStream { c = $0 }
        continuation = c
    }

    var sent: [String] { lock.withLock { _sent } }
    var terminated: Bool { lock.withLock { _terminated } }

    func send(line: String) throws { lock.withLock { _sent.append(line) } }
    func terminate() {
        lock.withLock { _terminated = true }
        continuation.finish()
    }
    func feed(_ line: String) { continuation.yield(line) }
    func finish() { continuation.finish() }

    /// Polls until `sent` holds at least `count` lines (generous timeout; no fixed sleeps).
    func waitForSent(_ count: Int, timeout: TimeInterval = 5) async -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        while sent.count < count, Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
        return sent
    }
}
