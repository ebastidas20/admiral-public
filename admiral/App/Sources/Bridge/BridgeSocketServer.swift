import Foundation
import AdmiralCore

/// Serves Admiral's `MCPServer` over a loopback Unix-domain socket so the bundled
/// `admiral-bridge-mcp` relay (inside an Admiral-hosted claude) and the hook helper can reach
/// this instance — roster / hail / broadcast / commission / set_goal / notify.
///
/// Protocol: one newline-terminated JSON line per connection,
/// `{"token": "<ADMIRAL_SESSION>", "request": <jsonrpc>}` → JSON response line. Every caller
/// here is a SESSION (`MCPServer.handle(envelope:)`): the operator tools are not served on it.
/// The socket itself (0600, same-uid peers only, timeouts, connection cap) is
/// `LineSocketServer`; this only hops each line onto the main actor, where BridgeCore lives.
@MainActor
final class BridgeSocketServer {
    private let server: LineSocketServer
    var path: String { server.path }

    init(mcp: MCPServer, path: String = BridgeSocketServer.defaultPath) {
        server = LineSocketServer(path: path) { line in
            DispatchQueue.main.sync { MainActor.assumeIsolated { mcp.handle(envelope: line) } }
        }
    }

    /// Fixed, well-known path the Python bridge derives the same way
    /// (`~/Library/Application Support/Admiral/bridge.sock`).
    nonisolated static var defaultPath: String {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Admiral", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("bridge.sock").path
    }

    func start() {
        // A failed bind leaves every session's bridge MCP unable to connect: say so.
        if !server.start() { NSLog("Admiral: bridge socket failed to listen at %@", server.path) }
    }

    func stop() { server.stop() }
}
