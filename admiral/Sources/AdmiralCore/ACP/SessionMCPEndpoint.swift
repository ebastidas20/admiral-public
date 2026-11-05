import Foundation

/// HTTP front door for the session bridge: `POST /mcp/session` on its own loopback listener
/// (default :4142). An ACP tab's agent — often in a container, where the bridge relay's Unix
/// socket is out of reach — calls Admiral's SESSION tools here as that one tab.
///
/// The bearer token is the only gate: `Authorization: Bearer <token>`, where the token is the
/// tab's `AgentSession.token` and `tokenIsLive` says whether it names an open ACP tab right now
/// (so a closed tab's token stops working at once). There is no Host allowlist — a container
/// reaches the Mac as `host.docker.internal` — but a request carrying `Origin` (a browser) is
/// refused before the token is looked at. The caller is always `.session(token)`: no token can
/// reach the operator tools here.
@MainActor
public struct SessionMCPEndpoint {
    public static let path = "/mcp/session"

    private let mcp: MCPServer
    private let tokenIsLive: (String) -> Bool

    public init(mcp: MCPServer, tokenIsLive: @escaping (String) -> Bool) {
        self.mcp = mcp
        self.tokenIsLive = tokenIsLive
    }

    public func handle(_ request: HTTPRequest) -> Data {
        if let origin = request.headers["origin"], !origin.isEmpty {
            return Self.jsonError(status: 403, code: -32003, message: "browser-originated request refused")
        }
        let route = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.path
        guard route == Self.path else {
            return Self.jsonError(status: 404, code: -32000, message: "not found: \(request.path)")
        }
        guard let token = Self.bearerToken(request.headers["authorization"]), tokenIsLive(token) else {
            return Self.jsonError(status: 401, code: -32001, message: "missing or unknown session token")
        }
        guard request.method == "POST" else {
            return Self.jsonError(status: 405, code: -32600,
                                  message: "use POST \(Self.path) with a JSON-RPC body")
        }
        let response = mcp.handle(requestData: request.body, caller: .session(token))
        // A notification (no id) gets no JSON-RPC answer.
        return HTTPWire.response(status: response.isEmpty ? 202 : 200, body: response)
    }

    /// The token of `Bearer <token>` (scheme case-insensitive, per RFC 9110); nil otherwise.
    static func bearerToken(_ header: String?) -> String? {
        guard let header else { return nil }
        let parts = header.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        let token = parts[1].trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }

    /// Byte-wise equality whose time depends only on the lengths, not on where the bytes
    /// first differ — so a caller cannot find a token one byte at a time by timing replies.
    public static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff: UInt8 = x.count == y.count ? 0 : 1
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0
            let r = i < y.count ? y[i] : 0
            diff |= l ^ r
        }
        return diff == 0
    }

    private static func jsonError(status: Int, code: Int, message: String) -> Data {
        let body: [String: Any] = ["jsonrpc": "2.0", "id": NSNull(), "error": ["code": code, "message": message]]
        return HTTPWire.response(status: status, body: (try? JSONSerialization.data(withJSONObject: body)) ?? Data())
    }
}

extension SessionManager {
    /// Whether `token` names an open ACP tab — the session bridge's credential check. Compares
    /// against every ACP tab in constant time per token, and reads the live list, so a closed
    /// tab's token is refused from the moment it closes. A PTY tab's token is never accepted:
    /// its claude reaches the bridge over the Unix-socket relay instead.
    public func acpTokenIsLive(_ token: String) -> Bool {
        var found = false
        for session in sessions where session.backend != .pty {
            if SessionMCPEndpoint.constantTimeEquals(session.token, token) { found = true }
        }
        return found
    }
}
