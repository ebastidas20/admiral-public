import XCTest
@testable import AdmiralCore

/// `list_acp_agents` / `add_acp_agent` / `edit_acp_agent` / `delete_acp_agent`: Settings →
/// Agents over the bridge, for a claude tab (or the operator) the user asked — never an ACP tab.
@MainActor
final class AcpAgentToolsTests: XCTestCase {
    private var saved: [AcpAgentConfig] = []
    private var manager: SessionManager!
    private var server: MCPServer!

    override func setUp() async throws {
        try await super.setUp()
        saved = []
        manager = SessionManager(host: FakeTerminalHost(), claudeHome: URL(fileURLWithPath: "/tmp/admiral-none"),
                                 executablePath: "/bin/echo")
        manager.acpAgents = { [unowned self] in saved }
        manager.register(AgentSession(callsign: "alice", cwd: "/a", token: "A"), handle: FakeTerminalHost.Handle(pid: 1))
        let bridge = BridgeCore(manager: manager, idGenerator: { "id" })
        bridge.saveAcpAgents = { [unowned self] in saved = $0 }
        server = MCPServer(bridge: bridge)
    }

    private func call(_ name: String, _ args: [String: Any], _ caller: MCPCaller = .session("A")) throws
        -> (isError: Bool, text: String) {
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                      "params": ["name": name, "arguments": args]]
        let data = try JSONSerialization.data(withJSONObject: request)
        let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: server.handle(requestData: data, caller: caller))
            as? [String: Any])
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        return (result["isError"] as? Bool ?? false,
                (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? "")
    }

    private func toolNames(_ caller: MCPCaller) throws -> Set<String> {
        let data = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8)
        let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: server.handle(requestData: data, caller: caller))
            as? [String: Any])
        let tools = (reply["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        return Set(tools.compactMap { $0["name"] as? String })
    }

    /// A Sailor agent over WebSocket with its agent and params in session `_meta`.
    func testAddWebSocketAgentWithSessionMetaParams() throws {
        let r = try call("add_acp_agent", [
            "name": "Sailor", "transport": "websocket", "url": "ws://127.0.0.1:8740/acp", "cwd": "/",
            "session_meta": ["agent": "researcher", "params": ["city": "Porto", "seats": 2]],
        ])
        XCTAssertFalse(r.isError, r.text)
        let a = try XCTUnwrap(saved.first)
        XCTAssertEqual(a.transport, .webSocket)
        XCTAssertEqual(a.url, "ws://127.0.0.1:8740/acp")
        XCTAssertEqual(a.workspace, .thisMac)
        XCTAssertEqual(a.sessionMeta, ["agent": .string("researcher"),
                                       "params": .object(["city": .string("Porto"), "seats": .number(2)])])
        // What a new tab sends: the params reach session/new's _meta.
        let params = AcpClient.newSessionParams(cwd: a.cwd, mcpServers: [], meta: a.sessionMeta)
        XCTAssertEqual(params["_meta"]?["params"]?["city"]?.stringValue, "Porto")

        let listed = try call("list_acp_agents", [:])
        XCTAssertTrue(listed.text.contains("Sailor [websocket] ws://127.0.0.1:8740/acp"), listed.text)
    }

    func testAddStdioAgentElsewhere() throws {
        let r = try call("add_acp_agent", [
            "name": "box", "command": "docker", "args": ["exec", "-i", "box", "claude-agent-acp"],
            "cwd": "/workspace", "runs_on": "elsewhere", "exec": ["docker", "exec", "box"],
            "bridge_url": "http://host.docker.internal:4142", "env": ["TOKEN": "x"],
            "starting_options": ["model": "opus"],
        ])
        XCTAssertFalse(r.isError, r.text)
        let a = try XCTUnwrap(saved.first)
        XCTAssertEqual(a.transport, .stdio)
        XCTAssertEqual(a.launch, AcpCommand(command: "docker", args: ["exec", "-i", "box", "claude-agent-acp"]))
        XCTAssertEqual(a.workspace, .elsewhere(exec: AcpCommand(command: "docker", args: ["exec", "box"])))
        XCTAssertEqual(a.mcpCallbackURL, "http://host.docker.internal:4142")
        XCTAssertEqual(a.env, ["TOKEN": "x"])
        XCTAssertEqual(a.defaultConfigOptions, ["model": "opus"])
        let listed = try call("list_acp_agents", [:]).text
        XCTAssertTrue(listed.contains("env=TOKEN"), listed)
        XCTAssertFalse(listed.contains("TOKEN=x"), "env values are not listed: \(listed)")
    }

    /// The Settings form's checks apply: nothing is saved when any fails.
    func testAddIsValidatedLikeSettings() throws {
        let cases: [([String: Any], String)] = [
            (["name": "a", "transport": "websocket", "url": "http://h/acp", "cwd": "/"], AcpAgentConfig.webSocketURLInvalid),
            (["name": "a", "cwd": "/"], "launch command is required"),
            (["name": "a", "command": "npx", "cwd": "relative"], "cwd must be an absolute path"),
            (["name": "a", "command": "npx", "cwd": "/", "runs_on": "elsewhere"], AcpAgentConfig.bridgeURLRequired),
            (["name": "a", "command": "npx", "cwd": "/", "session_meta": "[1]"], AcpAgentDraft.sessionMetaNotObject),
            (["name": "a", "command": "npx", "cwd": "/", "transport": "carrier-pigeon"], "transport must be"),
        ]
        for (args, expected) in cases {
            let r = try call("add_acp_agent", args)
            XCTAssertTrue(r.isError && r.text.contains(expected), "\(args) -> \(r.text)")
        }
        XCTAssertTrue(saved.isEmpty)

        XCTAssertFalse(try call("add_acp_agent", ["name": "Sailor", "command": "npx", "cwd": "/"]).isError)
        let dup = try call("add_acp_agent", ["name": "sailor", "command": "npx", "cwd": "/"])
        XCTAssertTrue(dup.isError && dup.text.contains("already exists"), dup.text)
        XCTAssertEqual(saved.count, 1)
    }

    func testEditChangesOnlyGivenFieldsAndDeleteRemoves() throws {
        XCTAssertFalse(try call("add_acp_agent", [
            "name": "Sailor", "transport": "websocket", "url": "ws://h:1/acp", "cwd": "/",
            "session_meta": ["agent": "a"],
        ]).isError)
        let id = saved[0].id
        let r = try call("edit_acp_agent", ["name": "SAILOR", "new_name": "Sailor 2",
                                            "session_meta": ["agent": "b", "params": ["x": "1"]]])
        XCTAssertFalse(r.isError, r.text)
        XCTAssertEqual(saved[0].id, id)
        XCTAssertEqual(saved[0].name, "Sailor 2")
        XCTAssertEqual(saved[0].url, "ws://h:1/acp", "untouched")
        XCTAssertEqual(saved[0].sessionMeta["agent"], .string("b"))

        XCTAssertTrue(try call("edit_acp_agent", ["name": "Sailor 2", "url": "nope"]).isError)
        XCTAssertEqual(saved[0].url, "ws://h:1/acp", "a refused edit saves nothing")
        XCTAssertTrue(try call("edit_acp_agent", ["name": "ghost"]).text.contains("no ACP agent"))

        XCTAssertFalse(try call("delete_acp_agent", ["name": "sailor 2"]).isError)
        XCTAssertTrue(saved.isEmpty)
    }

    /// A tab open on the agent finds it by name: rename and delete are refused, as in Settings.
    func testRenameAndDeleteRefusedWhileATabIsOpen() throws {
        XCTAssertFalse(try call("add_acp_agent", ["name": "box", "command": "npx", "cwd": "/"]).isError)
        var tab = AgentSession(callsign: "t", cwd: "/", token: "T")
        tab.backend = .acp(agentName: "box")
        manager.register(tab)
        XCTAssertEqual(try call("edit_acp_agent", ["name": "box", "new_name": "other"]).text,
                       "not saved: " + AcpAgentConfig.renameWithOpenTabs)
        XCTAssertEqual(try call("delete_acp_agent", ["name": "box"]).text, AcpAgentConfig.deleteWithOpenTabs)
        XCTAssertFalse(try call("edit_acp_agent", ["name": "box", "args": ["-y"]]).isError, "other edits are fine")
        XCTAssertEqual(saved.map(\.name), ["box"])
    }

    /// An ACP agent (possibly sandboxed elsewhere) must not configure an agent whose launch
    /// command runs on this Mac: refused, and the tools are not listed to it.
    func testACPTabCannotSeeOrCallTheTools() throws {
        var acp = AgentSession(callsign: "agent", cwd: "/", token: "P")
        acp.backend = .acp(agentName: "box")
        manager.register(acp)
        for name in MCPServer.acpAgentToolNames {
            let r = try call(name, ["name": "x", "command": "sh", "cwd": "/"], .session("P"))
            XCTAssertTrue(r.isError && r.text.contains("not available to an ACP agent's tab"), "\(name): \(r.text)")
        }
        XCTAssertTrue(saved.isEmpty)
        XCTAssertTrue(try toolNames(.session("P")).isDisjoint(with: MCPServer.acpAgentToolNames))
        XCTAssertTrue(MCPServer.acpAgentToolNames.isSubset(of: try toolNames(.session("A"))), "a claude tab sees them")
        XCTAssertTrue(MCPServer.acpAgentToolNames.isSubset(of: try toolNames(.operator)))
    }

    /// Every one of them tells the model it is for an explicit user request only.
    func testDescriptionsSayExplicitUserAskOnly() {
        for tool in MCPServer.acpAgentTools {
            let text = tool["description"] as? String ?? ""
            XCTAssertTrue(text.hasPrefix("ONLY call this when the user has explicitly asked you to"),
                          "\(tool["name"] ?? "?"): \(text)")
        }
        XCTAssertEqual(Set(MCPServer.acpAgentTools.compactMap { $0["name"] as? String }), MCPServer.acpAgentToolNames)
    }

    func testOperatorCanAddToo() throws {
        XCTAssertFalse(try call("add_acp_agent", ["name": "op", "command": "npx", "cwd": "/"], .operator).isError)
        XCTAssertEqual(saved.map(\.name), ["op"])
    }
}
