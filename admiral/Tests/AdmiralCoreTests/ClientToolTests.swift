import XCTest
@testable import AdmiralCore

final class ClientToolBrokerTests: XCTestCase {
    private func echo(_ id: String, name: String = "echo", value: Int = 1) -> TurnCapture.ToolUse {
        TurnCapture.ToolUse(id: id, name: name, input: .object(["x": .number(Double(value))]))
    }

    func testFIFOMatchesDuplicateCallsInOrder() {
        let broker = ClientToolBroker()
        broker.register(token: "t", name: "mcp__client__echo", arguments: .object(["x": .number(1)]))
        broker.register(token: "t", name: "echo", arguments: .object(["x": .number(1)]))
        let uses = [echo("toolu_a"), echo("toolu_b", name: "mcp__client__echo")]
        guard case let .ready(calls) = broker.correlate(token: "t", uses: uses) else {
            return XCTFail("expected a ready set")
        }
        XCTAssertEqual(calls.map(\.id), ["toolu_a", "toolu_b"])
        XCTAssertEqual(calls.map(\.name), ["echo", "echo"])
        XCTAssertEqual(broker.outstanding(token: "t").map(\.toolUseID), ["toolu_a", "toolu_b"])
    }

    func testPartialSetDoesNotStickIds() {
        let broker = ClientToolBroker()
        broker.register(token: "t", name: "echo", arguments: .object(["x": .number(1)]))
        let uses = [echo("toolu_a"), echo("toolu_missing", name: "other", value: 2)]
        XCTAssertEqual(broker.correlate(token: "t", uses: uses), .waiting)
        XCTAssertEqual(broker.outstanding(token: "t").map(\.toolUseID), [nil])
        guard case .ready = broker.correlate(token: "t", uses: [echo("toolu_a")]) else {
            return XCTFail("the unmatched id must still be free")
        }
        XCTAssertEqual(broker.outstanding(token: "t").map(\.toolUseID), ["toolu_a"])
    }

    func testCanonicalInputIgnoresKeyOrderAndIntegerEncoding() {
        let broker = ClientToolBroker()
        broker.register(token: "t", name: "echo",
                        arguments: .object(["b": .number(1), "a": .bool(true)]))
        let use = TurnCapture.ToolUse(
            id: "toolu_1", name: "echo",
            input: .object(["a": .bool(true), "b": .number(1)]))
        guard case let .ready(calls) = broker.correlate(token: "t", uses: [use]) else {
            return XCTFail("canonical input should match")
        }
        XCTAssertEqual(calls.first?.id, "toolu_1")
        XCTAssertEqual(CanonicalJSON.string(.object(["b": .number(1), "a": .bool(true)])),
                       "{\"a\":true,\"b\":1}")
    }

    func testJSONTrueStaysABoolean() throws {
        let data = try JSONSerialization.data(withJSONObject: ["ok": true])
        let parsed = try JSONSerialization.jsonObject(with: data)
        let value = ClientToolMCP.jsonValue(from: parsed)
        XCTAssertEqual(CanonicalJSON.string(value), "{\"ok\":true}")
    }

    func testFulfillAllIsAtomicAndEarlyResultReachesTheWaiter() async {
        let broker = ClientToolBroker()
        let id = broker.register(token: "t", name: "echo", arguments: .object(["x": .number(1)]))
        guard case .ready = broker.correlate(token: "t", uses: [echo("toolu_1")]) else {
            return XCTFail("correlate")
        }
        let block = ClientToolResultBlock(toolUseID: "toolu_1", result: .text("early"))
        XCTAssertFalse(broker.fulfillAll(token: "t", blocks: [block, block]),
                       "one park id cannot be fulfilled twice")
        XCTAssertEqual(broker.outstanding(token: "t").count, 1)
        XCTAssertTrue(broker.fulfillAll(token: "t", blocks: [block]))
        let result = await broker.wait(id)
        XCTAssertEqual(result.text, "early")
        XCTAssertFalse(result.isError)
    }

    func testFailUncorrelatedLeavesReportedParks() async {
        let broker = ClientToolBroker()
        broker.register(token: "t", name: "echo", arguments: .object(["x": .number(1)]))
        let leaked = broker.register(token: "t", name: "other", arguments: .object([:]))
        _ = broker.correlate(token: "t", uses: [echo("toolu_1")])
        let waiting = Task { await broker.wait(leaked) }
        broker.failUncorrelated(token: "t", message: "gave up")
        let failed = await waiting.value
        XCTAssertTrue(failed.isError)
        XCTAssertEqual(broker.outstanding(token: "t").map(\.toolUseID), ["toolu_1"])
    }
}

final class ClientToolContinuationTests: XCTestCase {
    private func park(_ id: String?) -> ClientToolParkView {
        ClientToolParkView(name: "echo", toolUseID: id)
    }
    private func result(_ id: String) -> ClientToolResultBlock {
        ClientToolResultBlock(toolUseID: id, result: .text("ok"))
    }

    func testExactSetMatches() {
        let decision = ClientToolContinuation.decide(
            outstanding: [park("toolu_b"), park("toolu_a")],
            results: [result("toolu_a"), result("toolu_b")],
            lastUserMessageHasText: false)
        guard case let .match(blocks) = decision else { return XCTFail("\(decision)") }
        XCTAssertEqual(blocks.map(\.toolUseID), ["toolu_a", "toolu_b"])
    }

    func testPartialSetAndPlainTextAreRefused() {
        let partial = ClientToolContinuation.decide(
            outstanding: [park("toolu_a"), park("toolu_b")],
            results: [result("toolu_a")], lastUserMessageHasText: false)
        guard case let .reject(partialMessage) = partial else { return XCTFail("\(partial)") }
        XCTAssertTrue(partialMessage.contains("toolu_a"))
        XCTAssertTrue(partialMessage.contains("toolu_b"))

        let text = ClientToolContinuation.decide(
            outstanding: [park("toolu_a")], results: [], lastUserMessageHasText: true)
        XCTAssertEqual(text, .reject(ClientToolContinuation.plainTextRefusal))
    }

    func testUncorrelatedParkIsRefused() {
        let decision = ClientToolContinuation.decide(
            outstanding: [park("toolu_a"), park(nil)],
            results: [result("toolu_a")], lastUserMessageHasText: false)
        XCTAssertEqual(decision, .reject(ClientToolContinuation.uncorrelatedRefusal))
    }
}

final class ClientToolMCPTests: XCTestCase {
    private let lucky = ClientToolSpec(
        name: "get_lucky_number", description: "always 7",
        inputSchema: .object(["type": .string("object")]))

    func testToolsListAdvertisesRealNames() throws {
        let line = #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#
        guard case let .reply(data) = ClientToolMCP.action(forLine: line, tools: [lucky]) else {
            return XCTFail("expected a reply")
        }
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try XCTUnwrap(obj["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.map { $0["name"] as? String }, ["get_lucky_number"])
        XCTAssertEqual(tools.first?["description"] as? String, "always 7")
        XCTAssertNotNil(tools.first?["inputSchema"])
    }

    func testInitializeAdvertisesListChanged() throws {
        let line = #"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}"#
        guard case let .reply(data) = ClientToolMCP.action(forLine: line, tools: []) else {
            return XCTFail("expected a reply")
        }
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"listChanged\":true"), text)
        let changed = ClientToolMCP.listChanged()
        let note = try XCTUnwrap(JSONSerialization.jsonObject(with: changed) as? [String: Any])
        XCTAssertEqual(note["method"] as? String, "notifications/tools/list_changed")
        XCTAssertNil(note["id"])
    }

    func testToolsCallParksInsteadOfRunning() {
        let line = #"{"jsonrpc":"2.0","id":"c1","method":"tools/call","params":{"name":"get_lucky_number","arguments":{}}}"#
        guard case let .park(id, name, arguments) = ClientToolMCP.action(forLine: line, tools: [lucky]) else {
            return XCTFail("expected a park")
        }
        XCTAssertEqual(id, .string("c1"))
        XCTAssertEqual(name, "get_lucky_number")
        XCTAssertEqual(arguments, .object([:]))
    }
}

final class ScheduleModelMappingTests: XCTestCase {
    func testHaikuAliases() {
        for raw in ["haiku", "HAIKU", "claude-haiku", "claude-3-5-haiku-latest", "claude-haiku-4-5"] {
            XCTAssertEqual(ScheduleModel(anthropicModel: raw), .haiku, raw)
        }
        XCTAssertEqual(ScheduleModel(anthropicModel: "claude-opus-4-8"), .opus)
        XCTAssertNil(ScheduleModel(anthropicModel: "haikuish"))
        XCTAssertNil(ScheduleModel(anthropicModel: "claude-custom-9"))
    }
}

final class ClientToolSocketTests: XCTestCase {
    func testTwoParksAreOutstandingBeforeEitherReturns() async throws {
        let broker = ClientToolBroker()
        let path = "/tmp/admiral-ct-\(UUID().uuidString.prefix(8)).sock"
        let server = ClientToolSocketServer(path: path, broker: broker)
        XCTAssertTrue(server.start())
        defer { server.stop() }
        let client = ClientToolSocketClient(path: path)
        XCTAssertTrue(client.connect())
        defer { client.close() }

        let first = Task { await client.park(token: "t", name: "a", arguments: .object(["n": .number(1)])) }
        let second = Task { await client.park(token: "t", name: "b", arguments: .object(["n": .number(2)])) }
        let deadline = Date().addingTimeInterval(2)
        while broker.outstanding(token: "t").count < 2, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(broker.outstanding(token: "t").count, 2)
        XCTAssertFalse(first.isCancelled)
        XCTAssertFalse(second.isCancelled)

        let uses = [
            TurnCapture.ToolUse(id: "toolu_1", name: "a", input: .object(["n": .number(1)])),
            TurnCapture.ToolUse(id: "toolu_2", name: "b", input: .object(["n": .number(2)])),
        ]
        guard case .ready = broker.correlate(token: "t", uses: uses) else {
            return XCTFail("both parks should correlate")
        }
        XCTAssertTrue(broker.fulfillAll(token: "t", blocks: [
            ClientToolResultBlock(toolUseID: "toolu_1", result: .text("one")),
            ClientToolResultBlock(toolUseID: "toolu_2", result: .text("two")),
        ]))
        let left = await first.value
        let right = await second.value
        XCTAssertEqual(Set([left.text, right.text]), ["one", "two"])
        XCTAssertFalse(left.isError)
        XCTAssertFalse(right.isError)
    }
}

@MainActor
final class ClientToolCommissionTests: XCTestCase {
    func testAPIToolTabPassesModelAndClientServer() throws {
        let fm = FileManager.default
        let support = fm.temporaryDirectory.appendingPathComponent("support-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: support) }
        let host = FakeTerminalHost()
        let zsh = AgentType(
            id: "claude_code", displayName: "Claude Code", executableName: "zsh",
            defaultArgs: ["-ilc", "claude --session-id \(SessionManager.sessionIDPlaceholder)"],
            symbolName: "sparkles")
        let manager = SessionManager(
            host: host, claudeHome: support.appendingPathComponent(".claude"),
            executablePath: "/bin/zsh",
            defaultAgentType: zsh, supportDir: support, hookHelper: "/X/admiral-hook",
            bridgeMCPCommand: "/X/admiral-bridge-mcp", clientMCPCommand: "/X/admiral-client-mcp",
            clientToolSocketPath: "/tmp/admiral-ct-test.sock")
        let tools = [ClientToolSpec(name: "get_lucky_number", description: "always 7",
                                    inputSchema: .object(["type": .string("object")]))]
        let session = manager.commission(callsign: "api", cwd: "/tmp", model: "haiku", clientTools: tools)

        let last = try XCTUnwrap(host.spawned.first?.args.last)
        XCTAssertTrue(last.contains("--model haiku"), last)
        XCTAssertTrue(last.contains("--strict-mcp-config"), last)
        XCTAssertTrue(last.contains("--permission-mode bypassPermissions"), last)
        XCTAssertTrue(last.contains("--tools \"\""), last)

        let settingsURL = AdmiralPaths.settingsFile(base: support, token: session.token)
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any])
        let permissions = try XCTUnwrap(settings["permissions"] as? [String: Any])
        XCTAssertEqual(permissions["defaultMode"] as? String, "bypassPermissions")
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: Any])
        let pre = try XCTUnwrap((hooks["PreToolUse"] as? [[String: Any]])?.first)
        XCTAssertNil(pre["matcher"], "API tool tabs match every tool")

        let mcpURL = AdmiralPaths.mcpConfigFile(base: support, token: session.token)
        let mcp = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: mcpURL)) as? [String: Any])
        let servers = try XCTUnwrap(mcp["mcpServers"] as? [String: Any])
        let client = try XCTUnwrap(servers["client"] as? [String: Any])
        XCTAssertEqual(client["command"] as? String, "/X/admiral-client-mcp")
        XCTAssertEqual(client["timeout"] as? Int, 600_000)
        let env = try XCTUnwrap(client["env"] as? [String: Any])
        XCTAssertEqual(env["ADMIRAL_SESSION"] as? String, session.token)
        XCTAssertEqual(env["ADMIRAL_CLIENT_SOCKET"] as? String, "/tmp/admiral-ct-test.sock")
        XCTAssertTrue(ClientToolCatalog.isEnabled(base: support, token: session.token))
        XCTAssertEqual(ClientToolCatalog.read(base: support, token: session.token).map(\.name),
                       ["get_lucky_number"])
    }
}

final class ClientToolHookTests: XCTestCase {
    func testPreToolUseDeniesBuiltInsAndAllowsClientTools() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ct-hook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let token = "tok"
        XCTAssertTrue(ClientToolCatalog.enable(base: base, token: token))
        ClientToolCatalog.write([
            ClientToolSpec(name: "get_lucky_number", inputSchema: .object(["type": .string("object")])),
        ], base: base, token: token)

        let bash = await HookDispatcher.handle(
            cliType: "claude", event: "PreToolUse",
            payload: Data(#"{"tool_name":"Bash","tool_input":{}}"#.utf8), base: base, token: token)
        XCTAssertTrue(bash?.contains("\"permissionDecision\":\"deny\"") ?? false)

        let bridge = await HookDispatcher.handle(
            cliType: "claude", event: "PreToolUse",
            payload: Data(#"{"tool_name":"mcp__bridge__inject","tool_input":{}}"#.utf8),
            base: base, token: token)
        XCTAssertTrue(bridge?.contains("deny") ?? false)

        let allowed = await HookDispatcher.handle(
            cliType: "claude", event: "PreToolUse",
            payload: Data(#"{"tool_name":"mcp__client__get_lucky_number","tool_input":{}}"#.utf8),
            base: base, token: token)
        XCTAssertNil(allowed)

        let prompt = await HookDispatcher.handle(
            cliType: "claude", event: "UserPromptSubmit",
            payload: Data(#"{}"#.utf8), base: base, token: token)
        XCTAssertTrue(prompt?.contains("ADMIRAL CLIENT TOOLS") ?? false)
        XCTAssertTrue(prompt?.contains("get_lucky_number") ?? false)
        XCTAssertFalse(prompt?.contains("systemMessage") ?? true)
    }
}
