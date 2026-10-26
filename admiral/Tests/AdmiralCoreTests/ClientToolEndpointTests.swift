import XCTest
@testable import AdmiralCore

@MainActor
final class ClientToolEndpointTests: XCTestCase {
    private var backend: FakeAnthropicBackend!
    private var endpoint: AnthropicEndpoint!
    private var transcript: URL!
    private var tabID: UUID!

    private static let cfg = AnthropicEndpoint.Config(
        busyWaitTimeout: 0.05, busySeenTimeout: 0.03, turnTimeout: 0.2,
        pollInterval: 0.01, pingInterval: 10,
        injectReadyTimeout: 0.05, injectVerifyTimeout: 0.02, injectMaxAttempts: 3)

    private let sid = "0b8f4a2e-1111-2222-3333-444455556666"

    override func setUp() async throws {
        backend = FakeAnthropicBackend()
        endpoint = AnthropicEndpoint(backend: backend, config: Self.cfg)
        tabID = UUID()
        transcript = FileManager.default.temporaryDirectory
            .appendingPathComponent("client-tools-\(UUID().uuidString).jsonl")
        try Data().write(to: transcript)
        backend.paths[tabID] = transcript.path
    }

    private func post(_ body: String, tab: String? = nil, headers extra: [String: String] = [:]) async -> (status: Int, json: [String: Any], raw: String) {
        var headers = extra
        if let tab { headers["admiral_tab_name"] = tab }
        let request = HTTPRequest(method: "POST", path: "/v1/messages", headers: headers, body: Data(body.utf8))
        var collected = Data()
        await endpoint.handle(request) { collected.append($0) }
        let text = String(data: collected, encoding: .utf8)!
        let status = Int(text.split(separator: " ")[1])!
        let bodyStart = text.range(of: "\r\n\r\n")!.upperBound
        let obj = (try? JSONSerialization.jsonObject(with: Data(text[bodyStart...].utf8))) as? [String: Any] ?? [:]
        return (status, obj, text)
    }

    private func postSID(_ body: String) async -> (status: Int, json: [String: Any], raw: String) {
        await post(body, headers: [
            "admiral_session_id": sid,
            "admiral_cwd": NSTemporaryDirectory(),
        ])
    }

    private func errorMessage(_ json: [String: Any]) -> String? {
        (json["error"] as? [String: Any])?["message"] as? String
    }

    private func toolBody(model: String = "claude-haiku-4-5",
                          user: String = "Call get_lucky_number.",
                          tools: Bool = true, stream: Bool = false) -> String {
        let toolJSON = tools ? """
        ,"tools":[{"name":"get_lucky_number","description":"always 7","input_schema":{"type":"object","properties":{}}}]
        """ : ""
        return """
        {"model":"\(model)","stream":\(stream),"messages":[{"role":"user","content":"\(user)"}]\(toolJSON)}
        """
    }

    private func userLine(_ text: String) -> String {
        "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\(jsonString(text))}}"
    }

    private func jsonString(_ text: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [text])
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }

    private func assistantTools(_ uses: [(id: String, name: String, input: [String: Any])] = [],
                                text: String? = nil) -> String {
        var content: [[String: Any]] = []
        if let text { content.append(["type": "text", "text": text]) }
        for use in uses {
            content.append(["type": "tool_use", "id": use.id, "name": use.name, "input": use.input])
        }
        let line: [String: Any] = [
            "type": "assistant",
            "message": [
                "role": "assistant", "content": content,
                "usage": ["input_tokens": 3, "output_tokens": 2],
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: line)
        return String(decoding: data, as: UTF8.self)
    }

    private func append(_ line: String) {
        let handle = try! FileHandle(forWritingTo: transcript)
        handle.seekToEndOfFile()
        handle.write(Data((line + "\n").utf8))
        try! handle.close()
    }

    /// Point scratch creation at the test transcript and remember it as an API tool tab.
    private func scriptCreation() {
        backend.createResult = { [self] _, _, _, tools in
            let tab = AnthropicTab(id: tabID, name: "api", isManaged: true)
            backend.paths[tab.id] = transcript.path
            backend.tabsBySession[sid] = tab
            if tools != nil { backend.clientToolTabs.insert(tab.id) }
            return tab
        }
    }

    private func scriptLuckyCall(name: String = "mcp__client__get_lucky_number", id: String = "toolu_lucky") {
        backend.onInject = { [self] n in
            guard n == 1 else { return }
            append(userLine("Call get_lucky_number."))
            append(assistantTools([(id, name, [:])]))
            let token = backend.sessionToken(tabID: tabID)!
            backend.clientToolBroker.register(token: token, name: "get_lucky_number", arguments: .object([:]))
        }
    }

    func testScratchTabHonorsHaikuAliasAndEchoesTheRequestModel() async {
        scriptCreation()
        scriptLuckyCall()
        let response = await postSID(toolBody())
        XCTAssertEqual(response.status, 200, response.raw)
        XCTAssertEqual(backend.created.first?.model, "haiku")
        XCTAssertEqual(backend.created.first?.clientTools?.map(\.name), ["get_lucky_number"])
        XCTAssertEqual(response.json["model"] as? String, "claude-haiku-4-5")
        XCTAssertEqual(response.json["stop_reason"] as? String, "tool_use")
        let block = (response.json["content"] as? [[String: Any]])?.first
        XCTAssertEqual(block?["type"] as? String, "tool_use")
        XCTAssertEqual(block?["id"] as? String, "toolu_lucky")
        XCTAssertEqual(block?["name"] as? String, "get_lucky_number")
        XCTAssertTrue(backend.installedTools.isEmpty, "commission already wrote the catalog")
    }

    func testUnknownModelPassesNoAlias() async {
        scriptCreation()
        backend.statuses = [.idle]
        backend.onInject = { [self] n in
            guard n == 1 else { return }
            append(userLine("hi"))
            append(assistantTools(text: "ok"))
        }
        // No tools: still a scratch create, and the model alias is what commission receives.
        let response = await postSID(toolBody(model: "claude-custom-9", user: "hi", tools: false))
        XCTAssertEqual(response.status, 200, response.raw)
        XCTAssertNil(backend.created.first?.model)
        XCTAssertEqual(response.json["model"] as? String, "claude-custom-9")
        XCTAssertEqual((response.json["content"] as? [[String: Any]])?.first?["text"] as? String, "ok")
    }

    func testNewPromptOnAToolTabStillWaitsOutBusy() async {
        scriptCreation()
        backend.statuses = [.busy]
        let response = await postSID(toolBody())
        XCTAssertEqual(response.status, 529, response.raw)
        XCTAssertTrue(backend.injected.isEmpty)
    }

    func testNamedTabWithToolsIs400() async {
        backend.tabs["Worker"] = AnthropicTab(id: tabID, name: "Worker", isManaged: true)
        let response = await post(toolBody(), tab: "Worker")
        XCTAssertEqual(response.status, 400)
        XCTAssertTrue(errorMessage(response.json)?.contains("API scratch session") ?? false)
        XCTAssertTrue(backend.injected.isEmpty)
        XCTAssertTrue(backend.created.isEmpty)
    }

    func testParallelToolUsesReturnTogether() async {
        scriptCreation()
        backend.onInject = { [self] n in
            guard n == 1 else { return }
            append(userLine("Call get_lucky_number."))
            append(assistantTools([
                ("toolu_one", "mcp__client__one", ["n": 1]),
                ("toolu_two", "mcp__client__two", ["n": 2]),
            ]))
            let token = backend.sessionToken(tabID: tabID)!
            backend.clientToolBroker.register(token: token, name: "one", arguments: .object(["n": .number(1)]))
            backend.clientToolBroker.register(token: token, name: "two", arguments: .object(["n": .number(2)]))
        }
        let body = """
        {"model":"claude-haiku-4-5","messages":[{"role":"user","content":"Call get_lucky_number."}],
         "tools":[
           {"name":"one","input_schema":{"type":"object"}},
           {"name":"two","input_schema":{"type":"object"}}
         ]}
        """
        let response = await postSID(body)
        XCTAssertEqual(response.status, 200, response.raw)
        let content = response.json["content"] as? [[String: Any]] ?? []
        XCTAssertEqual(content.map { $0["id"] as? String }, ["toolu_one", "toolu_two"])
        XCTAssertEqual(content.map { $0["name"] as? String }, ["one", "two"])
        XCTAssertEqual(response.json["stop_reason"] as? String, "tool_use")
    }

    func testPlainTextWhileOutstandingIs400() async {
        scriptCreation()
        scriptLuckyCall()
        let first = await postSID(toolBody())
        XCTAssertEqual(first.status, 200, first.raw)
        let text = """
        {"model":"claude-haiku-4-5","messages":[{"role":"user","content":"never mind, just answer"}]}
        """
        let second = await postSID(text)
        XCTAssertEqual(second.status, 400)
        XCTAssertEqual(errorMessage(second.json), ClientToolContinuation.plainTextRefusal)
        XCTAssertEqual(backend.injected.count, 1)
    }

    func testPartialContinuationIs400AndFullSetBypassesBusy() async {
        scriptCreation()
        backend.onInject = { [self] n in
            guard n == 1 else { return }
            append(userLine("Call get_lucky_number."))
            append(assistantTools([
                ("toolu_one", "one", ["n": 1]),
                ("toolu_two", "two", ["n": 2]),
            ]))
            let token = backend.sessionToken(tabID: tabID)!
            backend.clientToolBroker.register(token: token, name: "one", arguments: .object(["n": .number(1)]))
            backend.clientToolBroker.register(token: token, name: "two", arguments: .object(["n": .number(2)]))
        }
        let open = """
        {"model":"claude-haiku-4-5","messages":[{"role":"user","content":"Call get_lucky_number."}],
         "tools":[
           {"name":"one","input_schema":{"type":"object"}},
           {"name":"two","input_schema":{"type":"object"}}
         ]}
        """
        let first = await postSID(open)
        XCTAssertEqual(first.status, 200, first.raw)

        let partial = """
        {"model":"claude-haiku-4-5","messages":[{"role":"user","content":[
          {"type":"tool_result","tool_use_id":"toolu_one","content":"1"}
        ]}]}
        """
        let rejected = await postSID(partial)
        XCTAssertEqual(rejected.status, 400)
        XCTAssertTrue(errorMessage(rejected.json)?.contains("toolu_two") ?? false)
        XCTAssertEqual(backend.clientToolBroker.outstanding(token: backend.sessionToken(tabID: tabID)!).count, 2)

        backend.statuses = [.busy]
        var wroteFinal = false
        backend.onPoll = { [self] _ in
            guard !wroteFinal else { return }
            wroteFinal = true
            append(assistantTools(text: "the number is 7"))
        }
        let full = """
        {"model":"claude-haiku-4-5","messages":[{"role":"user","content":[
          {"type":"tool_result","tool_use_id":"toolu_one","content":"1"},
          {"type":"tool_result","tool_use_id":"toolu_two","content":"2"}
        ]}]}
        """
        let done = await postSID(full)
        XCTAssertEqual(done.status, 200, done.raw)
        XCTAssertEqual(done.json["stop_reason"] as? String, "end_turn")
        let text = ((done.json["content"] as? [[String: Any]])?.first)?["text"] as? String
        XCTAssertEqual(text, "the number is 7")
        XCTAssertEqual(backend.injected.count, 1, "a continuation must not type into the tab")
        XCTAssertFalse(backend.clientToolBroker.hasOutstanding(token: backend.sessionToken(tabID: tabID)!))
    }

    func testToolUseWithoutAParkIs500() async {
        scriptCreation()
        backend.onInject = { [self] n in
            guard n == 1 else { return }
            append(userLine("Call get_lucky_number."))
            append(assistantTools([("toolu_lucky", "mcp__client__get_lucky_number", [:])]))
        }
        let response = await postSID(toolBody())
        XCTAssertEqual(response.status, 500, response.raw)
        XCTAssertEqual(errorMessage(response.json), "client tool call was not parked")
    }

    func testStructuredOutputCannotCombineWithClientTools() async {
        let both = """
        {"model":"claude-haiku-4-5","messages":[{"role":"user","content":"q"}],
         "output_format":{"type":"json_schema","schema":{"type":"object"}},
         "tools":[{"name":"report","input_schema":{"type":"object"}}]}
        """
        let created = await postSID(both)
        XCTAssertEqual(created.status, 400)
        XCTAssertTrue(errorMessage(created.json)?.contains("cannot be combined") ?? false)
        XCTAssertTrue(backend.created.isEmpty, "a combined request must not commission a tab")

        backend.tabsBySession[sid] = AnthropicTab(id: tabID, name: "api", isManaged: true)
        backend.clientToolTabs.insert(tabID)
        let again = """
        {"model":"claude-haiku-4-5","messages":[{"role":"user","content":"q"}],
         "output_format":{"type":"json_schema","schema":{"type":"object"}}}
        """
        let response = await postSID(again)
        XCTAssertEqual(response.status, 400)
        XCTAssertTrue(errorMessage(response.json)?.contains("cannot be combined") ?? false)
        XCTAssertTrue(backend.injected.isEmpty)
    }

    func testStreamingToolUseWaitsUntilTheCallsExist() async {
        scriptCreation()
        scriptLuckyCall()
        let response = await postSID(toolBody(stream: true))
        XCTAssertTrue(response.raw.hasPrefix("HTTP/1.1 200"), response.raw)
        XCTAssertTrue(response.raw.contains("text/event-stream"))
        XCTAssertTrue(response.raw.contains("event: message_start"))
        let start = response.raw.range(of: "event: message_start")
        let block = response.raw.range(of: "event: content_block_start")
        XCTAssertLessThan(start?.lowerBound ?? response.raw.endIndex,
                          block?.lowerBound ?? response.raw.startIndex)
        XCTAssertTrue(response.raw.contains("\"name\":\"get_lucky_number\""))
        XCTAssertTrue(response.raw.contains("\"stop_reason\":\"tool_use\""))
        XCTAssertFalse(response.raw.contains("text_delta"),
                       "a parked turn does not open a text block before the tool call is known")
    }

    func testLaterRequestUpdatesTheCatalog() async {
        scriptCreation()
        scriptLuckyCall()
        let first = await postSID(toolBody())
        XCTAssertEqual(first.status, 200, first.raw)
        XCTAssertTrue(backend.installedTools.isEmpty)

        backend.onInject = { [self] n in
            guard n == 2 else { return }
            append(userLine("Call other."))
            let line: [String: Any] = [
                "type": "assistant",
                "message": [
                    "role": "assistant",
                    "content": [["type": "text", "text": "done"]],
                    "usage": ["input_tokens": 1, "output_tokens": 1],
                ],
            ]
            append(String(decoding: try! JSONSerialization.data(withJSONObject: line), as: UTF8.self))
        }
        // The first turn left a park outstanding; fulfill it so the next user text is legal.
        let token = backend.sessionToken(tabID: tabID)!
        let outstanding = backend.clientToolBroker.outstanding(token: token)
        XCTAssertEqual(outstanding.map(\.toolUseID), ["toolu_lucky"])
        XCTAssertTrue(backend.clientToolBroker.fulfillAll(token: token, blocks: [
            ClientToolResultBlock(toolUseID: "toolu_lucky", result: .text("7")),
        ]))
        let secondBody = """
        {"model":"claude-haiku-4-5","messages":[{"role":"user","content":"Call other."}],
         "tools":[{"name":"other","input_schema":{"type":"object"}}]}
        """
        let second = await postSID(secondBody)
        XCTAssertEqual(second.status, 200, second.raw)
        XCTAssertEqual(backend.installedTools[tabID]?.map(\.name), ["other"])
    }
}
