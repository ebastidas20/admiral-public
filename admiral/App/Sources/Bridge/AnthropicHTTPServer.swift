// admiral/App/Sources/Bridge/AnthropicHTTPServer.swift
import Foundation
import AdmiralCore

/// Serves the Anthropic-compatible chat API **and** operator MCP over the same
/// loopback TCP port (default 4141). Paths:
/// - `POST /v1/messages` → Anthropic chat
/// - `POST /mcp` → operator MCP
/// - `GET /sessions/<callsign>/events` → live SSE feed of one session
/// No route requires an API token. Browser-originated requests are still refused (the
/// endpoints check that, Host allowlist included).
///
/// The socket work is `LoopbackHTTPListener`'s (shared with the session bridge); this type is
/// only the routing.
@MainActor
final class AnthropicHTTPServer {
    private let listener: LoopbackHTTPListener
    var port: UInt16 { listener.port }

    init(endpoint: AnthropicEndpoint, mcpEndpoint: OperatorMCPEndpoint? = nil,
         eventsEndpoint: SessionEventsEndpoint? = nil) {
        // At most 32 connections in flight (a long SSE stream holds one).
        listener = LoopbackHTTPListener(label: "admiral.anthropic.http", connectionLimit: 32) { request, write in
            if let mcpEndpoint, OperatorMCPEndpoint.isMCPPath(request.path) {
                write(mcpEndpoint.handle(request))
            } else if let eventsEndpoint, SessionEventsEndpoint.callsign(inPath: request.path) != nil {
                // Long-lived: runs until the client hangs up (a failed write) or the tab closes.
                await eventsEndpoint.handle(request) { write($0) }
            } else {
                await endpoint.handle(request) { write($0) }
            }
        }
    }

    /// Bind 127.0.0.1:preferredPort, falling back to an ephemeral port; returns the
    /// bound port, or nil when even the fallback failed.
    func start(preferredPort: UInt16 = 4141) -> UInt16? {
        listener.start(preferredPort: preferredPort)
    }

    func stop() { listener.stop() }
}
