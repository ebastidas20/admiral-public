import Foundation

/// HTTP front door for operator MCP: `POST /mcp`.
/// Same `MCPServer` the Unix-socket BridgeMCP uses, called as `.operator`: the full tool
/// list, including the operator tools a session is refused. No API token is required
/// (Cloudflare Access gates the public hostname). Browser-originated requests are still refused.
@MainActor
public struct OperatorMCPEndpoint {
    private let mcp: MCPServer

    public init(mcp: MCPServer) {
        self.mcp = mcp
    }

    /// True when the request path is the operator MCP endpoint.
    public static func isMCPPath(_ path: String) -> Bool {
        let p = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        return p == "/mcp" || p == "/mcp/"
    }

    public func handle(_ request: HTTPRequest) -> Data {
        guard !request.looksBrowserOriginated else {
            return Self.jsonError(status: 403, code: -32003,
                                  message: "cross-origin or non-loopback request refused")
        }
        guard Self.isMCPPath(request.path) else {
            return Self.jsonError(status: 404, code: -32000, message: "not found: \(request.path)")
        }
        guard request.method == "POST" else {
            return Self.jsonError(status: 405, code: -32600,
                                  message: "use POST /mcp with a JSON-RPC body")
        }
        // Notifications (no id) return empty body with 202 in some transports; we still
        // run handle which returns empty Data for notifications.
        // This endpoint is the operator transport: the only place `.operator` is decided.
        let response = mcp.handle(requestData: request.body, caller: .operator)
        if response.isEmpty {
            return HTTPWire.response(status: 202, body: Data())
        }
        return HTTPWire.response(status: 200, body: response)
    }

    private static func jsonError(status: Int, code: Int, message: String) -> Data {
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": NSNull(),
            "error": ["code": code, "message": message],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        return HTTPWire.response(status: status, body: data)
    }
}
