import XCTest
@testable import AdmiralCore

@MainActor
final class OperatorMCPEndpointTests: XCTestCase {
    private let token = "adm_test_token_please"

    private func makeEndpoint() -> OperatorMCPEndpoint {
        let host = FakeTerminalHost()
        let manager = SessionManager(
            host: host,
            claudeHome: URL(fileURLWithPath: "/tmp/admiral-none"),
            executablePath: "/bin/echo"
        )
        manager.register(AgentSession(callsign: "alice", cwd: "/a", token: "A"),
                         handle: FakeTerminalHost.Handle(pid: 1))
        let bridge = BridgeCore(manager: manager, idGenerator: { "id123" })
        return OperatorMCPEndpoint(mcp: MCPServer(bridge: bridge))
    }

    private func request(method: String, path: String, headers: [String: String] = [:],
                         body: Data = Data()) -> HTTPRequest {
        HTTPRequest(method: method, path: path, headers: headers, body: body)
    }

    private func jsonRPCToolsList() -> Data {
        Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8)
    }

    /// No API token is required: a missing, wrong, or present key all list tools.
    func testUnauthenticatedRequestListsTools() {
        let ep = makeEndpoint()
        let bodies: [[String: String]] = [
            [:],
            ["authorization": "Bearer nope"],
            ["x-api-key": "nope"],
            ["x-api-key": token],
        ]
        for headers in bodies {
            let text = String(data: ep.handle(request(method: "POST", path: "/mcp", headers: headers,
                                                      body: jsonRPCToolsList())), encoding: .utf8) ?? ""
            XCTAssertTrue(text.hasPrefix("HTTP/1.1 200"), text)
            XCTAssertTrue(text.contains("list_sessions"), text)
            XCTAssertFalse(text.contains("unauthorized"), text)
        }
    }

    func testAcceptsBearerAndListsTools() {
        let ep = makeEndpoint()
        let raw = ep.handle(request(
            method: "POST", path: "/mcp",
            headers: ["authorization": "Bearer \(token)", "content-length": "0"],
            body: jsonRPCToolsList()
        ))
        let text = String(data: raw, encoding: .utf8) ?? ""
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200"), text)
        XCTAssertTrue(text.contains("list_sessions"), text)
        XCTAssertTrue(text.contains("inject"), text)
    }

    /// The endpoint is the operator: operator tools run with no token.
    func testAuthorizedCallerRunsOperatorTools() {
        let ep = makeEndpoint()
        let call = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_sessions","arguments":{}}}"#.utf8)
        let raw = ep.handle(request(method: "POST", path: "/mcp", body: call))
        let text = String(data: raw, encoding: .utf8) ?? ""
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200"), text)
        XCTAssertTrue(text.contains("@alice"), text)
        XCTAssertTrue(text.contains(#""isError":false"#), text)
    }

    /// A browser page (Origin) or a DNS-rebound hostname is refused. Loopback needs no token.
    func testBrowserOriginatedRequestIsRefused403() {
        let ep = makeEndpoint()
        for extra in [["origin": "https://evil.example"], ["host": "evil.example:4141"]] {
            let text = String(data: ep.handle(request(method: "POST", path: "/mcp", headers: extra,
                                                      body: jsonRPCToolsList())), encoding: .utf8) ?? ""
            XCTAssertTrue(text.hasPrefix("HTTP/1.1 403"), text)
            XCTAssertFalse(text.contains("list_sessions"), text)
        }
        let loopback = ep.handle(request(method: "POST", path: "/mcp",
                                         headers: ["host": "localhost:4141"],
                                         body: jsonRPCToolsList()))
        XCTAssertTrue((String(data: loopback, encoding: .utf8) ?? "").hasPrefix("HTTP/1.1 200"))
    }

    func testWrongPath404() {
        let ep = makeEndpoint()
        let raw = ep.handle(request(
            method: "POST", path: "/v1/messages",
            headers: ["authorization": "Bearer \(token)"],
            body: jsonRPCToolsList()
        ))
        let text = String(data: raw, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("404"), text)
    }

    func testTokenStoreMintsOnceIntoKeychainOnly() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("admiral-op-token-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = FakeMirror()
        let a = OperatorTokenStore.resolve(base: dir, mirror: m).token
        let b = OperatorTokenStore.resolve(base: dir, mirror: m).token
        XCTAssertEqual(a, b)
        XCTAssertTrue(a.hasPrefix("adm_"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: OperatorTokenStore.legacyTokenFile(base: dir).path))
    }
}
