// admiral/App/Sources/Bridge/SessionMCPHTTPServer.swift
import Foundation
import AdmiralCore

/// The session bridge listener: `POST /mcp/session` on 127.0.0.1:4142, where an ACP tab's
/// agent (in a container it reaches the Mac as `host.docker.internal:4142`) calls Admiral's
/// session tools as its own tab. Every rule — the bearer token, the Origin refusal, the path —
/// is `SessionMCPEndpoint`'s; there is deliberately no Host allowlist here (the token is the
/// gate), unlike the API server on :4141.
///
/// It never falls back to an ephemeral port: agents are told `mcpCallbackURL` (default
/// `http://host.docker.internal:4142`), so a listener anywhere else would be up but unreachable.
@MainActor
final class SessionMCPHTTPServer {
    static let defaultPort: UInt16 = 4142

    private let listener: LoopbackHTTPListener
    var port: UInt16 { listener.port }

    init(endpoint: SessionMCPEndpoint) {
        listener = LoopbackHTTPListener(label: "admiral.session-bridge.http", connectionLimit: 32) { request, write in
            _ = write(endpoint.handle(request))
        }
    }

    /// Bind 127.0.0.1:`port`; nil when it is taken (no fallback — see the type's note).
    func start(port: UInt16 = SessionMCPHTTPServer.defaultPort) -> UInt16? {
        listener.start(preferredPort: port, fallbackToEphemeral: false)
    }

    func stop() { listener.stop() }
}
