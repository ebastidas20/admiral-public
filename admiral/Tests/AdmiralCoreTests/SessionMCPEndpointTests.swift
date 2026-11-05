import XCTest
@testable import AdmiralCore

/// `POST /mcp/session` — the session bridge an ACP tab's agent (often in a container, where the
/// bridge relay's Unix socket is out of reach) calls Admiral's tools on. The bearer token is the
/// only gate, so every refusal is pinned here.
@MainActor
final class SessionMCPEndpointTests: XCTestCase {
    private var manager: SessionManager!
    private var endpoint: SessionMCPEndpoint!
    private var acpTab: AgentSession!

    override func setUp() async throws {
        try await super.setUp()
        manager = SessionManager(
            host: FakeTerminalHost(), claudeHome: URL(fileURLWithPath: "/tmp/admiral-none"),
            executablePath: "/bin/echo")
        var tab = AgentSession(callsign: "agent", cwd: "/workspace", token: "acp-token")
        tab.backend = .acp(agentName: "PPT")
        acpTab = tab
        manager.register(tab)
        manager.register(AgentSession(callsign: "mac", cwd: "/m", token: "pty-token"),
                         handle: FakeTerminalHost.Handle(pid: 2))
        let mcp = MCPServer(bridge: BridgeCore(manager: manager, idGenerator: { "id" }))
        endpoint = SessionMCPEndpoint(mcp: mcp, tokenIsLive: { [unowned self] in manager.acpTokenIsLive($0) })
    }

    // MARK: - Helpers

    private func request(
        path: String = SessionMCPEndpoint.path, method: String = "POST",
        headers: [String: String] = [:], body: String = #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#
    ) -> HTTPRequest {
        HTTPRequest(method: method, path: path, headers: headers, body: Data(body.utf8))
    }

    private func bearer(_ token: String) -> [String: String] { ["authorization": "Bearer \(token)"] }

    /// Status code and JSON body of an `HTTPWire` response.
    private func decode(_ data: Data) -> (status: Int, json: [String: Any]) {
        guard let headEnd = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<headEnd.lowerBound], encoding: .utf8) else { return (0, [:]) }
        let status = Int(head.split(separator: " ").dropFirst().first ?? "") ?? 0
        let body = data[headEnd.upperBound...]
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        return (status, json)
    }

    private func status(_ r: HTTPRequest) -> Int { decode(endpoint.handle(r)).status }

    private func toolNames(_ data: Data) -> Set<String> {
        let result = decode(data).json["result"] as? [String: Any]
        return Set((result?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? [])
    }

    // MARK: - Auth

    func testMissingBearerIs401() {
        XCTAssertEqual(status(request()), 401)
        XCTAssertEqual(status(request(headers: ["authorization": "acp-token"])), 401, "no Bearer scheme")
        XCTAssertEqual(status(request(headers: ["authorization": "Bearer "])), 401, "empty token")
        XCTAssertEqual(status(request(headers: ["authorization": "Basic acp-token"])), 401)
    }

    func testUnknownTokenIs401() {
        XCTAssertEqual(status(request(headers: bearer("nope"))), 401)
        XCTAssertEqual(status(request(headers: bearer("acp-toke"))), 401, "a prefix is not the token")
        XCTAssertEqual(status(request(headers: bearer("acp-token2"))), 401)
        // A Mac PTY tab's token is not a session-bridge credential: only ACP tabs are served here.
        XCTAssertEqual(status(request(headers: bearer("pty-token"))), 401)
        // The operator credential names no tab and is never accepted on this listener.
        XCTAssertEqual(status(request(headers: bearer(OperatorTokenStore.mcpSessionToken))), 401)
    }

    func testClosedTabTokenIsRejected() {
        XCTAssertEqual(status(request(headers: bearer("acp-token"))), 200)
        manager.delete(acpTab.id)
        XCTAssertEqual(status(request(headers: bearer("acp-token"))), 401)
    }

    func testValidTokenServesSessionToolsOnly() {
        let reply = endpoint.handle(request(headers: bearer("acp-token")))
        XCTAssertEqual(decode(reply).status, 200)
        let names = toolNames(reply)
        XCTAssertTrue(names.contains("hail"), "\(names)")
        XCTAssertTrue(names.isDisjoint(with: MCPServer.operatorTools), "\(names)")
    }

    /// The caller is the token's tab — the tool sees that tab as itself.
    func testValidTokenCallsAsThatTab() {
        let body = #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"callsign"}}"#
        let reply = decode(endpoint.handle(request(headers: bearer("acp-token"), body: body)))
        let content = (reply.json["result"] as? [String: Any])?["content"] as? [[String: Any]]
        XCTAssertEqual(content?.first?["text"] as? String, "agent")
    }

    /// The `Authorization` scheme is case-insensitive (RFC 9110); the token is not.
    func testBearerSchemeIsCaseInsensitive() {
        XCTAssertEqual(status(request(headers: ["authorization": "bearer acp-token"])), 200)
        XCTAssertEqual(status(request(headers: bearer("ACP-TOKEN"))), 401)
    }

    // MARK: - Refusals before auth

    func testOriginHeaderRefused() {
        let headers = bearer("acp-token").merging(["origin": "http://evil.example"]) { $1 }
        XCTAssertEqual(status(request(headers: headers)), 403)
    }

    /// No Host allowlist: a container reaches the Mac as `host.docker.internal`.
    func testAnyHostIsServed() {
        let headers = bearer("acp-token").merging(["host": "host.docker.internal:4142"]) { $1 }
        XCTAssertEqual(status(request(headers: headers)), 200)
    }

    func testWrongPathIs404() {
        XCTAssertEqual(status(request(path: "/mcp", headers: bearer("acp-token"))), 404)
        XCTAssertEqual(status(request(path: "/v1/messages", headers: bearer("acp-token"))), 404)
        XCTAssertEqual(status(request(path: "/mcp/session/x", headers: bearer("acp-token"))), 404)
        XCTAssertEqual(status(request(path: "/mcp/session?x=1", headers: bearer("acp-token"))), 200)
    }

    func testNonPostIs405() {
        XCTAssertEqual(status(request(method: "GET", headers: bearer("acp-token"), body: "")), 405)
    }

    /// A JSON-RPC notification (`notifications/initialized`) gets 202 and no body.
    func testNotificationIs202() {
        let body = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
        XCTAssertEqual(status(request(headers: bearer("acp-token"), body: body)), 202)
    }

    func testConstantTimeEquals() {
        XCTAssertTrue(SessionMCPEndpoint.constantTimeEquals("abc", "abc"))
        XCTAssertFalse(SessionMCPEndpoint.constantTimeEquals("abc", "abd"))
        XCTAssertFalse(SessionMCPEndpoint.constantTimeEquals("abc", "abcd"))
        XCTAssertFalse(SessionMCPEndpoint.constantTimeEquals("", "a"))
    }
}
