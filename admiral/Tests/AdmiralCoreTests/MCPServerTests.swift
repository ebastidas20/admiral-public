import XCTest
@testable import AdmiralCore

@MainActor
final class MCPServerTests: XCTestCase {
    private func makeServer() -> (MCPServer, FakeTerminalHost) {
        let host = FakeTerminalHost()
        let manager = SessionManager(
            host: host,
            claudeHome: URL(fileURLWithPath: "/tmp/admiral-none"),
            executablePath: "/bin/echo"
        )
        manager.register(AgentSession(callsign: "alice", cwd: "/a", token: "A"), handle: FakeTerminalHost.Handle(pid: 1))
        manager.register(AgentSession(callsign: "bob", cwd: "/b", token: "B"), handle: FakeTerminalHost.Handle(pid: 2))
        let bridge = BridgeCore(manager: manager, idGenerator: { "id123" })
        return (MCPServer(bridge: bridge), host)
    }

    private func parse(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private static let operatorToolNames: Set<String> = [
        "inject", "list_sessions", "session_status", "focus", "close_session",
        "read_recent", "read_screen", "send_keys", "commission_bash", "fleet_pr_status",
    ]
    private static let sessionToolNames: Set<String> = [
        "callsign", "notify", "roster", "hail", "broadcast", "set_goal", "set_goal_self",
        "update_goals", "commission", "rename_station", "set_structured_output", "pr_status",
        "add_goals", "AskUserQuestion", "set_output_schema", "schedule_list", "schedule_set",
        "schedule_delete", "schedule_run", "schedule_history",
    ]

    private func toolNames(_ server: MCPServer, _ caller: MCPCaller) -> [String] {
        let request = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8)
        let result = parse(server.handle(requestData: request, caller: caller))["result"] as? [String: Any]
        return (result?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
    }

    func testOperatorToolsListReturnsAllTools() {
        let (server, _) = makeServer()
        let names = toolNames(server, .operator)
        XCTAssertEqual(names.count, 30)
        XCTAssertEqual(Set(names), Self.sessionToolNames.union(Self.operatorToolNames))
        XCTAssertEqual(MCPServer.operatorTools, Self.operatorToolNames)
    }

    /// A session never sees the operator tools — the app withholds them, not the relay.
    func testSessionToolsListLeavesOutTheOperatorTools() {
        let (server, _) = makeServer()
        let names = toolNames(server, .session("A"))
        XCTAssertEqual(names.count, 20)
        XCTAssertEqual(Set(names), Self.sessionToolNames)
    }

    /// The operator tools act on any tab with no sender identity. A session asking for one —
    /// even by naming another tab it knows — is refused before anything is typed, read or closed.
    func testSessionCallerIsRefusedEveryOperatorTool() throws {
        let (server, host) = makeServer()
        let cwd = FileManager.default.temporaryDirectory.path
        let args: [String: [String: Any]] = [
            "inject": ["to": "bob", "text": "typed"], "send_keys": ["callsign": "bob", "keys": "x"],
            "read_screen": ["callsign": "bob"], "read_recent": ["callsign": "bob"],
            "close_session": ["callsign": "bob"], "commission_bash": ["callsign": "sh", "cwd": cwd],
            "list_sessions": [:], "session_status": ["callsign": "bob"], "focus": ["callsign": "bob"],
            "fleet_pr_status": [:],
        ]
        XCTAssertEqual(Set(args.keys), Self.operatorToolNames)
        for (name, arguments) in args {
            let reply = try call(server, name, arguments, .session("A"))
            XCTAssertTrue(reply.isError, name)
            XCTAssertTrue(reply.text.contains("\(name) is an operator tool"), reply.text)
        }
        XCTAssertEqual(host.sent, [], "nothing was typed into a tab")
        XCTAssertEqual(toolNames(server, .operator).count, 30)
        XCTAssertFalse(try call(server, "list_sessions", [:], .operator).text.contains("sh"),
                       "no bash tab was commissioned")
        XCTAssertTrue(try call(server, "list_sessions", [:], .operator).text.contains("@bob"),
                      "bob was not closed")
    }

    /// The socket has no operator credential: its envelope is a session caller whatever its
    /// token says, including the operator's internal token.
    func testEnvelopeIsASessionCallerEvenWithTheOperatorToken() throws {
        let (server, host) = makeServer()
        func envelope(_ token: String, _ request: [String: Any]) throws -> [String: Any] {
            let data = try JSONSerialization.data(withJSONObject: ["token": token, "request": request])
            return parse(server.handle(envelope: data))
        }
        let inject: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                     "params": ["name": "inject", "arguments": ["to": "bob", "text": "typed"]]]
        for token in [OperatorTokenStore.mcpSessionToken, "A"] {
            let result = try XCTUnwrap(try envelope(token, inject)["result"] as? [String: Any])
            XCTAssertEqual(result["isError"] as? Bool, true, token)
        }
        XCTAssertEqual(host.sent, [])
        let list = try envelope(OperatorTokenStore.mcpSessionToken,
                                ["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let names = ((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])?
            .compactMap { $0["name"] as? String } ?? []
        XCTAssertFalse(names.isEmpty)
        XCTAssertTrue(Set(names).isDisjoint(with: Self.operatorToolNames), "\(names)")
    }

    /// A token that names no tab is no identity at all: every tool is refused, including the
    /// ones that never needed a sender (commission, schedule_*).
    func testSessionTokenThatNamesNoTabIsRefusedEveryTool() throws {
        let (server, _) = makeServer()
        let cwd = FileManager.default.temporaryDirectory.path
        for (name, arguments) in [("roster", [:]), ("commission", ["callsign": "ghost", "cwd": cwd]),
                                  ("schedule_list", [:]), ("set_output_schema", ["callsign": "bob", "schema": ""]),
                                  ("rename_station", ["name": "x", "to": "bob"])] as [(String, [String: Any])] {
            for token in ["Z", "", OperatorTokenStore.mcpSessionToken] {
                let reply = try call(server, name, arguments, .session(token))
                XCTAssertTrue(reply.isError, "\(name) as \(token)")
                XCTAssertTrue(reply.text.contains("names no Admiral tab"), reply.text)
            }
        }
        let sessions = try call(server, "list_sessions", [:], .operator).text
        XCTAssertFalse(sessions.contains("ghost"), "nothing was commissioned")
        XCTAssertTrue(sessions.contains("@bob"), "bob was not renamed")
    }

    /// A session renames, and sets the output schema of, only its own tab; the operator any.
    func testOwnTabToolsRefuseAnotherTabForASessionButNotTheOperator() throws {
        let (server, _) = makeServer()
        let peerRename = try call(server, "rename_station", ["name": "mallory", "to": "bob"], .session("A"))
        XCTAssertTrue(peerRename.isError)
        XCTAssertTrue(peerRename.text.contains("rename_station changes only your own tab (@alice)"), peerRename.text)
        let peerSchema = try call(server, "set_output_schema", ["callsign": "BOB", "schema": ""], .session("A"))
        XCTAssertTrue(peerSchema.isError)
        XCTAssertTrue(peerSchema.text.contains("set_output_schema changes only your own tab"), peerSchema.text)
        XCTAssertTrue(try call(server, "list_sessions", [:], .operator).text.contains("@bob"), "bob kept its name")

        // Naming yourself, or nobody, is your own tab.
        XCTAssertFalse(try call(server, "rename_station", ["name": "alice2", "to": "alice"], .session("A")).isError)
        XCTAssertFalse(try call(server, "rename_station", ["name": "alice3"], .session("A")).isError)
        let ownSchema = try call(server, "set_output_schema", ["callsign": "alice3", "schema": ""], .session("A"))
        XCTAssertFalse(ownSchema.text.contains("only your own tab"), ownSchema.text)

        // The operator renames any tab.
        XCTAssertFalse(try call(server, "rename_station", ["name": "robert", "to": "bob"], .operator).isError)
        XCTAssertTrue(try call(server, "list_sessions", [:], .operator).text.contains("@robert"))
    }

    private func call(_ server: MCPServer, _ name: String, _ args: [String: Any],
                      _ caller: MCPCaller) throws -> (isError: Bool, text: String) {
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                      "params": ["name": name, "arguments": args]]
        let data = try JSONSerialization.data(withJSONObject: request)
        let result = try XCTUnwrap(parse(server.handle(requestData: data, caller: caller))["result"]
            as? [String: Any])
        return (result["isError"] as? Bool ?? false,
                (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? "")
    }

    /// `goals` has to reach the model as a real array, or it will send a comma-joined
    /// string and every goal after the first disappears.
    func testSetGoalAdvertisesAnArrayOfStrings() {
        let tool = MCPServer.tools.first { $0["name"] as? String == "set_goal" }
        let schema = tool?["inputSchema"] as? [String: Any]
        let properties = schema?["properties"] as? [String: Any]
        let goals = properties?["goals"] as? [String: Any]
        XCTAssertEqual(goals?["type"] as? String, "array")
        XCTAssertEqual((goals?["items"] as? [String: Any])?["type"] as? String, "string")
        XCTAssertEqual(properties?["to"] as? [String: Any] as? [String: String], ["type": "string"])
        XCTAssertEqual(Set(schema?["required"] as? [String] ?? []), ["to", "goals"])
    }

    /// `type` is optional on set_structured_output — a session with one armed slot never
    /// has to name it.
    func testStructuredOutputTypeIsOptional() {
        let tool = MCPServer.tools.first { $0["name"] as? String == "set_structured_output" }
        let schema = tool?["inputSchema"] as? [String: Any]
        XCTAssertEqual(schema?["required"] as? [String], ["output"])
        let properties = schema?["properties"] as? [String: Any]
        XCTAssertNotNil(properties?["type"])
    }

    /// The description is the only guidance a caller gets while composing goals, and it has
    /// to steer past two failures — each shown by example, not merely described: a goal
    /// nothing can close (which, since an open goal keeps the session probed and nagged, runs
    /// it forever) and one that names the command instead of the change ("swift test passes"
    /// — provable, and true of every task ever asked). It must NOT rule out kinds of work:
    /// a refactor that was asked for is a goal like any other.
    func testBothSetGoalToolsTeachOutcomeShapedGoals() {
        for name in ["set_goal", "set_goal_self"] {
            let description = MCPServer.tools
                .first { $0["name"] as? String == name }?["description"] as? String ?? ""
            XCTAssertTrue(description.contains("THIS REQUEST asked for"), name)
            XCTAssertTrue(description.contains("PROVES the goal, it is never the goal"), name)
            XCTAssertTrue(description.contains("CLOSEABLE"), name)
            XCTAssertTrue(description.contains("able to FAIL"),
                          "\(name) rules out a goal that is true even when the work is broken")
            XCTAssertTrue(description.contains("bullet by bullet"),
                          "\(name) stops the list becoming a transcript of the request")
            XCTAssertTrue(description.contains("QUIETLY"),
                          "\(name) points the slots at silent failures")
            XCTAssertTrue(description.contains("probed, nagged"),
                          "\(name) names the cost of an open-ended goal")
            XCTAssertTrue(description.contains("One outcome per goal"), name)
            XCTAssertTrue(description.contains("Asked to refactor"),
                          "\(name) bans unasked work, not kinds of work")
            XCTAssertTrue(description.contains("true of any task"),
                          "\(name) says WHY a command is a bad goal")
            XCTAssertTrue(description.contains("swift test passes"),
                          "\(name) shows the mechanical failure by example")
            XCTAssertTrue(description.contains("make auth robust"),
                          "\(name) shows the never-closing failure by example")
            XCTAssertTrue(description.contains("monitor the deploy"),
                          "\(name) rules out a standing state, not just a vague one")
            XCTAssertTrue(description.contains("280"), "\(name) states the limits")
        }
    }

    /// The guidance is a file the user (or a session) can rewrite. `tools/list` reads it at
    /// the moment it answers, so an edit reaches the next session without restarting Admiral.
    func testGoalGuidanceIsReadFromTheSupportDirAtListTime() throws {
        let host = FakeTerminalHost()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-guidance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let manager = SessionManager(host: host, executablePath: "/bin/echo", supportDir: base)
        manager.register(AgentSession(callsign: "alice", cwd: "/a", token: "A"),
                         handle: FakeTerminalHost.Handle(pid: 1))
        let server = MCPServer(bridge: BridgeCore(manager: manager))
        let list = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8)

        func description(of name: String) throws -> String {
            let result = try XCTUnwrap(parse(server.handle(requestData: list, sessionToken: "A"))["result"] as? [String: Any])
            let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
            return tools.first { $0["name"] as? String == name }?["description"] as? String ?? ""
        }

        XCTAssertTrue(try description(of: "set_goal_self").contains("THIS REQUEST asked for"), "built-in")

        GoalGuidance.set("Goals must rhyme.", base: base)
        let custom = try description(of: "set_goal_self")
        XCTAssertTrue(custom.contains("Goals must rhyme."), custom)
        XCTAssertFalse(custom.contains("make auth robust"), "the override replaces, not appends")
        XCTAssertTrue(custom.contains("280"), "the enforced limits are always stated")

        GoalGuidance.set("   ", base: base)
        XCTAssertTrue(try description(of: "set_goal_self").contains("THIS REQUEST asked for"),
                      "emptying the file resets to the built-in")
    }

    func testGoalTextsAcceptsListAndBareStringButNotAbsence() {
        XCTAssertEqual(MCPServer.goalTexts(["goals": ["a", "b"]]), ["a", "b"])
        XCTAssertEqual(MCPServer.goalTexts(["goals": []]), [], "an empty list means clear")
        XCTAssertEqual(MCPServer.goalTexts(["goal": "just one"]), ["just one"])
        XCTAssertNil(MCPServer.goalTexts(["to": "bob"]), "forgetting the argument is not clearing")
    }

    func testToolsCallSetGoalStoresWithoutTyping() {
        let host = FakeTerminalHost()
        let manager = SessionManager(
            host: host, claudeHome: URL(fileURLWithPath: "/tmp/admiral-none"), executablePath: "/bin/echo"
        )
        manager.register(AgentSession(callsign: "alice", cwd: "/a", claudeSessionID: "sid-a", token: "A"),
                         handle: FakeTerminalHost.Handle(pid: 1))
        let goals = GoalsStore(base: FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-goals-\(UUID().uuidString)"))
        let server = MCPServer(bridge: BridgeCore(manager: manager, goalsStore: goals))

        let call = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"set_goal_self","arguments":{"goals":["ship it","verify in rnd"]}}}"#
        let result = parse(server.handle(requestData: Data(call.utf8), sessionToken: "A"))["result"] as? [String: Any]
        XCTAssertEqual(result?["isError"] as? Bool, false)
        XCTAssertEqual(goals.goals(forSession: "sid-a")?.goals.count, 2)
        XCTAssertEqual(host.sent, [], "no /goal line")
    }

    /// The tool takes no arguments and reports the watcher's file — including the case where
    /// nothing is watching, which the caller must be able to tell apart from "no PR".
    func testPRStatusReportsTheWatchedStateOrWhyThereIsNone() throws {
        let host = FakeTerminalHost()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-prwatch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let manager = SessionManager(host: host, executablePath: "/bin/echo", supportDir: base)
        manager.register(AgentSession(callsign: "alice", cwd: "/a", claudeSessionID: "sid-a", token: "A"),
                         handle: FakeTerminalHost.Handle(pid: 1))
        let server = MCPServer(bridge: BridgeCore(manager: manager))
        let call = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"pr_status","arguments":{}}}"#.utf8)

        var response = parse(server.handle(requestData: call, sessionToken: "A"))
        var result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        var text = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        XCTAssertTrue(text.contains("watchdog is armed"), text)

        var state = PRWatchState()
        state.repos["/Users/x/admiral"] = [PRDigest(number: 920, title: "t", url: "https://gh/920",
                                                    state: .mergeable, checks: .passed, approvals: 1)]
        state.checkedAt = Date()
        PRWatchStore(base: base).set(state, forSession: "sid-a")

        response = parse(server.handle(requestData: call, sessionToken: "A"))
        result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        text = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        XCTAssertTrue(text.contains("admiral #920 mergeable · checks passed · 1 approval"), text)
        XCTAssertTrue(text.contains("checked 0s ago"), text)
    }

    /// `cancelled` used to be advertised and then dropped on the floor between the tool call
    /// and the bridge, so cancelling reported "0 goals updated" and changed nothing. And
    /// `done` used to be required, so a cancel-only call was rejected by the client before
    /// Admiral ever saw it. Both are one call away from being silently broken again.
    func testUpdateGoalsCancelsWithoutADoneList() throws {
        let host = FakeTerminalHost()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let manager = SessionManager(host: host, executablePath: "/bin/echo", supportDir: base)
        manager.register(AgentSession(callsign: "alice", cwd: "/a", claudeSessionID: "sid-a", token: "A"),
                         handle: FakeTerminalHost.Handle(pid: 1))
        let goals = GoalsStore(base: base)
        let server = MCPServer(bridge: BridgeCore(manager: manager, goalsStore: goals))

        guard case let .success(seeded) = SessionGoals.make(from: ["ship it", "verify it"]) else {
            return XCTFail("fixture must be valid")
        }
        goals.set(seeded, forSession: "sid-a")

        let schema = MCPServer.tools.first { $0["name"] as? String == "update_goals" }?["inputSchema"] as? [String: Any]
        XCTAssertEqual(schema?["required"] as? [String], [], "no list is required")

        let call = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"update_goals","arguments":{"cancelled":["g1","g2"]}}}"#
        let result = try XCTUnwrap(parse(server.handle(requestData: Data(call.utf8), sessionToken: "A"))["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        XCTAssertEqual(goals.goals(forSession: "sid-a")?.goals.map(\.status), [.cancelled, .cancelled])
        XCTAssertEqual(goals.goals(forSession: "sid-a")?.visible, [], "cancelled leaves the panel")
    }

    /// Cancelling has no preconditions: a met goal, a mixed list, the whole list at once —
    /// all of it goes. Nothing about a goal's current status may stand in the way of clearing
    /// it, since "cancel everything and start over" is the one move that must always work.
    func testAnyGoalCanBeCancelledIncludingOnesAlreadyMet() throws {
        let host = FakeTerminalHost()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-cancel-any-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let manager = SessionManager(host: host, executablePath: "/bin/echo", supportDir: base)
        manager.register(AgentSession(callsign: "alice", cwd: "/a", claudeSessionID: "sid-a", token: "A"),
                         handle: FakeTerminalHost.Handle(pid: 1))
        let goals = GoalsStore(base: base)
        let server = MCPServer(bridge: BridgeCore(manager: manager, goalsStore: goals))
        guard case let .success(seeded) = SessionGoals.make(from: ["ship it", "verify it", "document it"]) else {
            return XCTFail("fixture must be valid")
        }
        goals.set(seeded, forSession: "sid-a")

        func call(_ arguments: String) throws -> [String: Any] {
            let json = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"update_goals","arguments":\#(arguments)}}"#
            return try XCTUnwrap(parse(server.handle(requestData: Data(json.utf8), sessionToken: "A"))["result"] as? [String: Any])
        }

        XCTAssertEqual(try call(#"{"done":["g1"]}"#)["isError"] as? Bool, false)
        XCTAssertEqual(goals.goals(forSession: "sid-a")?.goals.first?.status, .met)

        // g1 is already met, g2 is open, g3 untouched — cancel all three in one call.
        let result = try call(#"{"cancelled":["g1","g2","g3"]}"#)
        XCTAssertEqual(result["isError"] as? Bool, false)
        XCTAssertEqual(goals.goals(forSession: "sid-a")?.goals.map(\.status),
                       [.cancelled, .cancelled, .cancelled],
                       "a met goal cancels like any other")
        XCTAssertEqual(goals.goals(forSession: "sid-a")?.visible, [])

        // And with nothing open, a fresh list replaces them without a refusal.
        let fresh = #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"set_goal_self","arguments":{"goals":["start over"]}}}"#
        let replaced = try XCTUnwrap(parse(server.handle(requestData: Data(fresh.utf8), sessionToken: "A"))["result"] as? [String: Any])
        XCTAssertEqual(replaced["isError"] as? Bool, false)
        XCTAssertEqual(goals.goals(forSession: "sid-a")?.goals.map(\.text), ["start over"])
    }

    /// …but a call that names nothing is a mistake, not a no-op.
    func testUpdateGoalsWithNoIdsIsRefused() throws {
        let (server, _) = makeServer()
        let call = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"update_goals","arguments":{}}}"#
        let result = try XCTUnwrap(parse(server.handle(requestData: Data(call.utf8), sessionToken: "A"))["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        XCTAssertTrue(text.contains("name at least one goal id"), text)
    }

    func testToolsCallRoster() {
        let (server, _) = makeServer()
        let request = Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"roster","arguments":{}}}"#.utf8)
        let response = parse(server.handle(requestData: request, sessionToken: "A"))
        let result = response["result"] as? [String: Any]
        let content = (result?["content"] as? [[String: Any]])?.first?["text"] as? String
        XCTAssertEqual(result?["isError"] as? Bool, false)
        XCTAssertTrue(content?.contains("@bob") == true)
        XCTAssertTrue(content?.contains("claude_code") == true)
    }

    func testToolsCallHailDeliversTheBodyVerbatim() {
        let (server, host) = makeServer()
        let request = Data(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"hail","arguments":{"to":"bob","body":"ping"}}}"#.utf8)
        let response = parse(server.handle(requestData: request, sessionToken: "A"))
        let result = response["result"] as? [String: Any]
        XCTAssertEqual(result?["isError"] as? Bool, false)
        XCTAssertTrue(host.combined.contains("ping"))
        // Verbatim: no framed header wraps a hail any more.
        XCTAssertFalse(host.combined.contains("from:   @alice"))
        // And it asks for nothing back unless the caller says needs_reply.
        XCTAssertFalse(host.combined.contains("reply requested"))
    }

    /// `needs_reply` arrives as a JSON boolean, so the schema has to declare it as one —
    /// a "string" here has the client reject `true` before Admiral ever sees the call.
    func testHailNeedsReplyIsABooleanAndIsOptional() {
        let schema = MCPServer.tools.first { $0["name"] as? String == "hail" }?["inputSchema"] as? [String: Any]
        let props = schema?["properties"] as? [String: Any]
        XCTAssertEqual((props?["needs_reply"] as? [String: Any])?["type"] as? String, "boolean")
        XCTAssertEqual(Set(schema?["required"] as? [String] ?? []), ["to", "body"])
    }

    /// A handoff brief that narrates the user ("Sam asked… they have authorized…") reads as a
    /// go-between relaying orders, and the receiver discounts it as hearsay. The description
    /// is the only place the sender learns the voice.
    func testHailTeachesBriefsAsDirectInstructions() {
        let description = MCPServer.tools
            .first { $0["name"] as? String == "hail" }?["description"] as? String ?? ""
        XCTAssertTrue(description.contains("imperative voice"), description)
        XCTAssertTrue(description.contains("The prod deploy is authorized."), description)
        XCTAssertTrue(description.contains("authorizations as facts of the task"), description)
        XCTAssertTrue(description.contains("addressed to the receiver"), description)
        XCTAssertTrue(description.contains("in your own voice as the sender"), description)
    }

    func testToolsCallHailWithNeedsReplyAsksForOne() {
        let (server, host) = makeServer()
        let request = Data(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"hail","arguments":{"to":"bob","body":"ping","needs_reply":true}}}"#.utf8)
        let response = parse(server.handle(requestData: request, sessionToken: "A"))
        XCTAssertEqual((response["result"] as? [String: Any])?["isError"] as? Bool, false)
        XCTAssertTrue(host.combined.contains("reply requested"), host.combined)
        XCTAssertTrue(host.combined.contains("in_reply_to"), host.combined)
    }

    func testOperatorInjectTypesRawText() {
        let (server, host) = makeServer()
        // The operator is no session; inject types the verbatim text (no hail framing) into @bob.
        let request = Data(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"inject","arguments":{"to":"bob","text":"verbatim relay payload"}}}"#.utf8)
        let response = parse(server.handle(requestData: request, caller: .operator))
        let result = response["result"] as? [String: Any]
        XCTAssertEqual(result?["isError"] as? Bool, false)
        XCTAssertTrue(host.combined.contains("verbatim relay payload"))
        XCTAssertFalse(host.combined.contains("incoming hail"))
    }

    func testHandleEnvelopeExtractsTokenAndForwards() {
        let (server, _) = makeServer()
        // The loopback socket protocol: {"token": ..., "request": <jsonrpc>}.
        let envelope = Data(#"""
        {"token":"A","request":{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"callsign","arguments":{}}}}
        """#.utf8)
        let response = parse(server.handle(envelope: envelope))
        let result = response["result"] as? [String: Any]
        let content = (result?["content"] as? [[String: Any]])?.first?["text"] as? String
        XCTAssertEqual(content, "alice", "envelope token A resolves to that session's callsign")
    }

    func testHandleEnvelopeMalformedErrors() {
        let (server, _) = makeServer()
        let response = parse(server.handle(envelope: Data("not json".utf8)))
        XCTAssertNotNil(response["error"])
    }

    func testUnknownMethodErrors() {
        let (server, _) = makeServer()
        let request = Data(#"{"jsonrpc":"2.0","id":4,"method":"bogus"}"#.utf8)
        let response = parse(server.handle(requestData: request, sessionToken: "A"))
        XCTAssertNotNil(response["error"])
    }

    func testOperatorToolsHaveAgentFacingDescriptions() {
        let names = ["list_sessions", "session_status", "focus", "close_session",
                     "read_recent", "read_screen", "send_keys", "commission_bash", "fleet_pr_status",
                     "callsign", "roster", "broadcast", "inject", "commission"]
        for name in names {
            let description = MCPServer.tools
                .first { $0["name"] as? String == name }?["description"] as? String ?? ""
            XCTAssertGreaterThan(description.count, 80, "\(name) description too thin for agents")
            XCTAssertTrue(description.contains("Use ") || description.contains("OPERATOR")
                          || description.contains("Prefer") || description.contains("Return"),
                          "\(name) should teach when/how: \(description.prefix(60))")
        }
    }

    func testListSessionsAndFocusAndClose() {
        let (server, _) = makeServer()
        func call(_ name: String, _ args: [String: Any] = [:]) -> (ok: Bool, text: String) {
            let params: [String: Any] = ["name": name, "arguments": args]
            let req: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": params]
            let data = try! JSONSerialization.data(withJSONObject: req)
            let response = parse(server.handle(requestData: data, caller: .operator))
            let result = response["result"] as? [String: Any]
            let content = (result?["content"] as? [[String: Any]])?.first
            let text = content?["text"] as? String ?? ""
            let isError = result?["isError"] as? Bool ?? true
            return (!isError, text)
        }
        let list = call("list_sessions")
        XCTAssertTrue(list.ok)
        XCTAssertTrue(list.text.contains("@alice"))
        XCTAssertTrue(list.text.contains("@bob"))

        let status = call("session_status", ["callsign": "alice"])
        XCTAssertTrue(status.ok)
        XCTAssertTrue(status.text.contains("@alice"))

        let focused = call("focus", ["callsign": "bob"])
        XCTAssertTrue(focused.ok)

        let closed = call("close_session", ["callsign": "bob"])
        XCTAssertTrue(closed.ok)
        let after = call("list_sessions")
        XCTAssertFalse(after.text.contains("@bob"))
        XCTAssertTrue(after.text.contains("@alice"))
    }

    /// `scratch: true` lands a scratch tab under the caller's callsign; omitting it follows
    /// the setting (`scratchByDefault`), re-read per call; `scratch: false` overrides it.
    func testCommissionScratchFlagAndDefault() {
        let manager = SessionManager(host: FakeTerminalHost(),
                                     claudeHome: URL(fileURLWithPath: "/tmp/admiral-none"),
                                     executablePath: "/bin/echo")
        let bridge = BridgeCore(manager: manager)
        let server = MCPServer(bridge: bridge)
        let cwd = FileManager.default.temporaryDirectory.path
        func commission(_ tool: String, _ args: [String: Any]) -> AgentSession? {
            let params: [String: Any] = ["name": tool, "arguments": args]
            let req: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": params]
            _ = server.handle(requestData: try! JSONSerialization.data(withJSONObject: req), caller: .operator)
            return manager.sessions.first { $0.callsign == args["callsign"] as? String }
        }
        let scout = commission("commission", ["callsign": "scout", "cwd": cwd, "scratch": true])
        XCTAssertEqual(scout?.scratch, true)
        XCTAssertEqual(scout?.displayTitle, "scout", "a scratch tab keeps the caller's callsign")
        XCTAssertEqual(commission("commission", ["callsign": "plain", "cwd": cwd])?.scratch, false)
        XCTAssertEqual(commission("commission_bash", ["callsign": "sh1", "cwd": cwd, "scratch": true])?.scratch, true)

        let spaced = commission("commission", ["callsign": "night shift", "cwd": cwd])
        XCTAssertNil(spaced, "no tab keeps the spaced name")
        XCTAssertNotNil(manager.sessions.first { $0.displayTitle == "night-shift" },
                        "commission hyphenates spaces in the tab name")

        bridge.scratchByDefault = { true }
        XCTAssertEqual(commission("commission", ["callsign": "dflt", "cwd": cwd])?.scratch, true)
        XCTAssertEqual(commission("commission", ["callsign": "keep", "cwd": cwd, "scratch": false])?.scratch, false)
    }

    func testReadRecentMissingStation() {
        let (server, _) = makeServer()
        let params: [String: Any] = ["name": "read_recent", "arguments": ["callsign": "nope"]]
        let req: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": params]
        let data = try! JSONSerialization.data(withJSONObject: req)
        let response = parse(server.handle(requestData: data, caller: .operator))
        let result = response["result"] as? [String: Any]
        XCTAssertEqual(result?["isError"] as? Bool, true)
        let text = ((result?["content"] as? [[String: Any]])?.first)?["text"] as? String ?? ""
        XCTAssertTrue(text.contains("no station @nope"), text)
    }

    func testFleetPrStatusEmpty() {
        let (server, _) = makeServer()
        let params: [String: Any] = ["name": "fleet_pr_status", "arguments": [:]]
        let req: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": params]
        let data = try! JSONSerialization.data(withJSONObject: req)
        let response = parse(server.handle(requestData: data, caller: .operator))
        let result = response["result"] as? [String: Any]
        let text = ((result?["content"] as? [[String: Any]])?.first)?["text"] as? String ?? ""
        XCTAssertEqual(result?["isError"] as? Bool, false)
        XCTAssertTrue(text.contains("no PR status"))
    }



    // MARK: - ACP callers

    /// Answers `test -d` like an agent environment holding only `dirs`, and records every call.
    private final class DirRunner: CommandRunner, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [[String]] = []
        var calls: [[String]] { lock.withLock { _calls } }
        let dirs: Set<String>
        init(dirs: Set<String>) { self.dirs = dirs }
        func run(_ argv: [String], cwd: String?, timeout: TimeInterval) -> (code: Int32, stdout: String)? {
            lock.withLock { _calls.append(argv) }
            if argv.count == 3, argv[0] == "test", argv[1] == "-d" { return (dirs.contains(argv[2]) ? 0 : 1, "") }
            return (1, "")
        }
    }

    /// A manager with one PTY tab (token "A") and one ACP tab on agent "PPT" (token "P"), whose
    /// environment holds `/workspace` and `/workspace/sub`. `runner` nil = the agent has no exec.
    private func makeACPServer(
        runner: DirRunner? = DirRunner(dirs: ["/workspace", "/workspace/sub"])
    ) -> (MCPServer, SessionManager, FakeTerminalHost) {
        let host = FakeTerminalHost()
        let manager = SessionManager(host: host, claudeHome: URL(fileURLWithPath: "/tmp/admiral-none"),
                                     executablePath: "/bin/echo",
                                     supportDir: FileManager.default.temporaryDirectory
                                        .appendingPathComponent("mcp-acp-\(UUID().uuidString)"))
        let ppt = AcpAgentConfig(name: "PPT", launch: AcpCommand(command: "docker", args: ["exec", "-i", "c", "a"]),
                                 cwd: "/workspace")
        manager.acpAgents = { [ppt] }
        manager.acpRunnerFactory = { _ in runner }
        manager.acpTransportFactory = { _, _ in ScriptedAgent() }
        manager.register(AgentSession(callsign: "alice", cwd: "/a", token: "A"),
                         handle: FakeTerminalHost.Handle(pid: 1))
        var acp = AgentSession(callsign: "agent", cwd: "/workspace", token: "P")
        acp.backend = .acp(agentName: "PPT")
        manager.register(acp)
        return (MCPServer(bridge: BridgeCore(manager: manager, idGenerator: { "id" })), manager, host)
    }

    /// An ACP tab asking for a new tab gets one on its OWN agent, in the agent's environment —
    /// never a claude on the Mac. The cwd is checked there (`test -d`), not with the Mac's
    /// FileManager: `/workspace/sub` does not exist on this Mac.
    func testCommissionFromACPCallerOpensTabOnSameAgent() throws {
        let runner = DirRunner(dirs: ["/workspace", "/workspace/sub"])
        let (server, manager, host) = makeACPServer(runner: runner)
        let reply = try call(server, "commission", ["callsign": "helper", "cwd": "/workspace/sub"], .session("P"))
        XCTAssertFalse(reply.isError, reply.text)
        let made = try XCTUnwrap(manager.sessions.first { $0.callsign == "helper" })
        XCTAssertEqual(made.backend, .acp(agentName: "PPT"))
        XCTAssertNotEqual(made.backend, .pty)
        XCTAssertEqual(made.cwd, "/workspace/sub")
        XCTAssertTrue(host.spawned.isEmpty, "nothing was spawned on the Mac: \(host.spawned)")
        XCTAssertTrue(runner.calls.contains(["test", "-d", "/workspace/sub"]), "\(runner.calls)")
        manager.terminateAll()
    }

    func testCommissionFromACPCallerChecksCwdInTheAgentsEnvironment() throws {
        let (server, manager, host) = makeACPServer()
        let missing = try call(server, "commission", ["callsign": "x", "cwd": "/workspace/nope"], .session("P"))
        XCTAssertTrue(missing.isError)
        XCTAssertEqual(missing.text, "cwd /workspace/nope is not a directory in PPT's environment")
        // A Mac folder means nothing there either.
        let mac = FileManager.default.temporaryDirectory.path
        XCTAssertTrue(try call(server, "commission", ["callsign": "y", "cwd": mac], .session("P")).isError)
        XCTAssertNil(manager.sessions.first { ["x", "y"].contains($0.callsign) })
        // Omitted = the agent's own cwd.
        XCTAssertFalse(try call(server, "commission", ["callsign": "z"], .session("P")).isError)
        XCTAssertEqual(manager.sessions.first { $0.callsign == "z" }?.cwd, "/workspace")
        XCTAssertTrue(host.spawned.isEmpty)
        manager.terminateAll()
    }

    /// No exec = nowhere to check: the tab opens in the agent's configured cwd, unchecked.
    func testCommissionFromACPCallerWithoutExecUsesTheAgentsCwd() throws {
        let (server, manager, host) = makeACPServer(runner: nil)
        let reply = try call(server, "commission", ["callsign": "w", "cwd": "/elsewhere"], .session("P"))
        XCTAssertFalse(reply.isError, reply.text)
        let made = try XCTUnwrap(manager.sessions.first { $0.callsign == "w" })
        XCTAssertEqual(made.backend, .acp(agentName: "PPT"))
        XCTAssertEqual(made.cwd, "/workspace")
        XCTAssertTrue(reply.text.contains("no exec command"), reply.text)
        XCTAssertTrue(host.spawned.isEmpty)
        manager.terminateAll()
    }

    /// A CC Switch provider is a Mac claude's endpoint; an ACP agent has its own model.
    func testCommissionFromACPCallerRefusesAProvider() throws {
        let (server, manager, host) = makeACPServer()
        let reply = try call(server, "commission", ["callsign": "p", "provider": "Kimi"], .session("P"))
        XCTAssertTrue(reply.isError)
        XCTAssertEqual(reply.text, "provider applies only to claude tabs on the Mac, not to an ACP agent's tab")
        XCTAssertNil(manager.sessions.first { $0.callsign == "p" })
        XCTAssertTrue(host.spawned.isEmpty)
    }

    func testScheduleSetFromACPCallerRefused() throws {
        let (server, _, _) = makeACPServer()
        for name in ["schedule_set", "schedule_list", "schedule_delete", "schedule_run", "schedule_history"] {
            let reply = try call(server, name, ["name": "nightly", "cron": "0 3 * * *", "prompt": "hi"],
                                 .session("P"))
            XCTAssertTrue(reply.isError, name)
            XCTAssertEqual(reply.text, "schedules can't target ACP agents yet", name)
        }
    }

    func testCommissionFromPTYCallerUnchanged() throws {
        let (server, manager, host) = makeACPServer()
        let cwd = FileManager.default.temporaryDirectory.path
        let reply = try call(server, "commission", ["callsign": "mac-tab", "cwd": cwd], .session("A"))
        XCTAssertFalse(reply.isError, reply.text)
        let made = try XCTUnwrap(manager.sessions.first { $0.callsign == "mac-tab" })
        XCTAssertEqual(made.backend, .pty)
        XCTAssertEqual(host.spawned.count, 1)
        // The Mac folder check still applies to a PTY caller.
        let missing = try call(server, "commission", ["callsign": "m2", "cwd": "/workspace/sub"], .session("A"))
        XCTAssertTrue(missing.isError)
        XCTAssertEqual(missing.text, "cwd is required and must be an existing directory")
        // And schedules are still theirs.
        XCTAssertNotEqual(try call(server, "schedule_list", [:], .session("A")).text,
                          "schedules can't target ACP agents yet")
    }
}
