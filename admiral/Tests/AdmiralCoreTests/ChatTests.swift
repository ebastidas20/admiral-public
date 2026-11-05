import XCTest
@testable import AdmiralCore

/// The Chat view's data path: hook payloads → ledger → fold, the built-in AskUserQuestion
/// deny, the bridge mirror, and what the composer types.
final class ChatHookTests: XCTestCase {
    private var base: URL!
    private let token = "chat-tok"
    private let sid = "11111111-2222-3333-4444-555555555555"

    override func setUp() {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("chat-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: base) }

    @discardableResult
    private func dispatch(_ event: String, _ payload: [String: Any]) async -> String? {
        var body = payload
        body["session_id"] = sid
        body["hook_event_name"] = event
        let data = try! JSONSerialization.data(withJSONObject: body)
        return await HookDispatcher.handle(cliType: "claude", event: event, payload: data,
                                           base: base, token: token)
    }

    private var chat: ChatTranscript { ChatFolder.fold(ChatLedger.read(base: base, session: sid)) }

    /// The reply comes from the Stop payload — the exact shape claude 2.1.278 sends.
    func testStopRecordsTheLastAssistantMessage() async {
        await dispatch("UserPromptSubmit", ["prompt": "fix it"])
        await dispatch("Stop", ["stop_hook_active": false, "last_assistant_message": "Fixed."])
        XCTAssertEqual(chat.items.count, 2)
        guard case let .prompt(_, text, source, _) = chat.items[0] else { return XCTFail("\(chat.items)") }
        XCTAssertEqual(text, "fix it")
        XCTAssertNil(source, "typed by the user")
        guard case let .reply(_, reply, _) = chat.items[1] else { return XCTFail("\(chat.items)") }
        XCTAssertEqual(reply, "Fixed.")
    }

    /// A reply, once shown, never changes: a later Stop in the same turn (a hook blocked the
    /// first) is just another reply, and the earlier one renders exactly as before.
    func testALaterStopNeverChangesAnEarlierReply() async {
        await dispatch("UserPromptSubmit", ["prompt": "hello"])
        await dispatch("Stop", ["last_assistant_message": "Hello!"])
        let before = chat.items
        await dispatch("Stop", ["stop_hook_active": true, "last_assistant_message": "No goals to set."])
        XCTAssertEqual(Array(chat.items.prefix(before.count)), before, "earlier items are untouched")
        guard case let .reply(_, last, _) = chat.items.last else { return XCTFail("\(chat.items)") }
        XCTAssertEqual(last, "No goals to set.")
    }

    func testEmptyStopMessageAddsNothing() async {
        await dispatch("Stop", ["last_assistant_message": "  "])
        await dispatch("Stop", [:])
        XCTAssertTrue(chat.items.isEmpty)
    }

    /// A prompt Admiral typed (a goal nudge, a hail) is attributed, not shown as the user's.
    func testInjectedPromptCarriesItsSource() async {
        ChatLedger.markInjected("Goal check:  are you   done?", source: "goals", base: base, session: sid)
        await dispatch("UserPromptSubmit", ["prompt": "Goal check: are you done?"])
        await dispatch("UserPromptSubmit", ["prompt": "Goal check: are you done?"])
        let sources = chat.items.compactMap { item -> String?? in
            if case let .prompt(_, _, source, _) = item { return source }
            return nil
        }
        XCTAssertEqual(sources, ["goals", nil], "a marker is consumed once")
    }

    func testPastedContentWrapperIsNotShown() async {
        await dispatch("UserPromptSubmit",
                       ["prompt": "\n\n<pasted_content id=\"7136\">\nhello there\n</pasted_content id=\"7136\">\n"])
        guard case let .prompt(_, text, _, _) = chat.items.first else { return XCTFail() }
        XCTAssertEqual(text, "hello there")
    }

    func testOnlyBlockingNotificationsBecomeNeedsYou() async {
        await dispatch("Notification", ["notification_type": "idle_prompt", "message": "waiting"])
        XCTAssertTrue(chat.items.isEmpty)
        await dispatch("Notification", ["notification_type": "permission_prompt",
                                        "message": "Claude needs your permission to use Bash"])
        XCTAssertTrue(chat.isWaiting)
        await dispatch("Stop", ["last_assistant_message": "Pushed."])
        XCTAssertFalse(chat.isWaiting, "any later event means the prompt was dealt with")
    }

    // MARK: - Built-in AskUserQuestion

    private func preToolUse(_ tool: String) async -> String? {
        await dispatch("PreToolUse", ["tool_name": tool, "tool_input": ["questions": []]])
    }

    /// Exact wire JSON: a wrong key silently lets claude's dialog open in a Chat tab.
    func testChatModeDeniesTheBuiltInWithExactJSON() async throws {
        ChatLedger.setMode(.chat, base: base, session: sid)
        let denied = await preToolUse("AskUserQuestion")
        let out = try XCTUnwrap(denied, "chat mode = deny")
        XCTAssertEqual(out, #"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","#
            + #""permissionDecisionReason":"The user is in Admiral's chat view, where the built-in "#
            + #"AskUserQuestion cannot be answered. Call mcp__bridge__AskUserQuestion with exactly the "#
            + #"same input instead. If that tool is unavailable, ask the questions as plain text in "#
            + #"your reply and end your turn."}}"#)
    }

    func testTerminalModeLeavesTheBuiltInAlone() async {
        ChatLedger.setMode(.terminal, base: base, session: sid)
        let out = await preToolUse("AskUserQuestion")
        XCTAssertNil(out, "a Terminal-mode tab keeps claude's own dialog")
        ChatLedger.setMode(.chat, base: base, session: sid)
        let back = await preToolUse("AskUserQuestion")
        XCTAssertNotNil(back, "switching back to Chat denies again — read per call, not cached")
    }

    func testOtherToolsAreNeverDenied() async {
        let out = await preToolUse("Bash")
        XCTAssertNil(out)
    }

    // MARK: - Fold

    private func ask() -> ChatEvent {
        ChatEvent(ts: "t", kind: .ask, questions: [
            AskQuestion(question: "Pick a color?", header: "Color",
                        options: [AskOption(label: "Red"), AskOption(label: "Green")]),
        ])
    }

    /// The mirror returns at once and the turn ends, so the reply after an ask must not
    /// close it — only the next prompt (the answers) does.
    func testAskStaysOpenThroughTheReplyAndClosesOnTheNextPrompt() {
        var events = [ChatEvent(ts: "1", kind: .prompt, text: "go"), ask(),
                      ChatEvent(ts: "2", kind: .reply, text: "Waiting for your answers.")]
        XCTAssertNotNil(ChatFolder.fold(events).openAsk)
        events.append(ChatEvent(ts: "3", kind: .prompt, text: "My answers: …"))
        XCTAssertNil(ChatFolder.fold(events).openAsk)
    }

    /// `.resolved` (an ACP request answered outside a prompt) closes the open cards and draws
    /// nothing; a card that comes after it is open again.
    func testResolvedClosesOpenCardsAndDrawsNothing() {
        var events = [ChatEvent(ts: "1", kind: .prompt, text: "go"), ask(),
                      ChatEvent(ts: "2", kind: .needs, text: "Run rm")]
        XCTAssertTrue(ChatFolder.fold(events).isWaiting)
        events.append(ChatEvent(ts: "3", kind: .resolved))
        let folded = ChatFolder.fold(events)
        XCTAssertFalse(folded.isWaiting)
        XCTAssertNil(folded.openAsk)
        XCTAssertEqual(folded.items.count, 3, "no item of its own")
        events.append(ChatEvent(ts: "4", kind: .needs, text: "Run make"))
        XCTAssertTrue(ChatFolder.fold(events).isWaiting)
    }

    private let stoppedTask = """
        <task-notification>
        <task-id>task-fixture-1</task-id>
        <tool-use-id>toolu_fixture_0001</tool-use-id>
        <status>stopped</status>
        <summary>Background shell command didn't finish before the previous session ended</summary>
        <note>No completion record was found for it in the previous session.</note>
        </task-notification>
        """

    /// A task notification arrives as a prompt but is the harness talking: it renders as a
    /// plain notice with its summary (and a non-ordinary status), never a raw-XML user bubble.
    func testTaskNotificationRendersAsItsSummary() async {
        await dispatch("UserPromptSubmit", ["prompt": stoppedTask])
        guard case let .notice(_, text, _) = chat.items.first else { return XCTFail("\(chat.items)") }
        XCTAssertEqual(text, "Background shell command didn't finish before the previous session ended (stopped)")
        XCTAssertFalse(chat.items.contains { if case .prompt = $0 { return true } else { return false } })
    }

    func testCompletedTaskShowsJustTheSummary() {
        let done = "<task-notification><status>completed</status><summary>Build finished</summary></task-notification>"
        XCTAssertEqual(TaskNotification.message(done), "Build finished")
        XCTAssertNil(TaskNotification.message("an ordinary prompt"))
    }

    /// It isn't the user's answer, so an open question card stays open through it.
    func testTaskNotificationDoesNotAnswerAnOpenQuestion() {
        let events = [ask(), ChatEvent(ts: "2", kind: .prompt, text: stoppedTask)]
        XCTAssertNotNil(ChatFolder.fold(events).openAsk)
    }

    func testAnswerTextUsesClaudesJoiner() {
        let questions = [
            AskQuestion(question: "Pick a color?", header: "Color", options: []),
            AskQuestion(question: "Which pets?", header: "Pets", multiSelect: true, options: []),
        ]
        XCTAssertEqual(AskAnswer.text(questions: questions, answers: ["Green", "Cats, Birds"]),
                       "My answers:\n- Pick a color? → Green\n- Which pets? → Cats, Birds")
    }
}

@MainActor
final class ChatMirrorTests: XCTestCase {
    private var base: URL!
    private var manager: SessionManager!
    private var server: MCPServer!
    private let sid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        manager = SessionManager(host: FakeTerminalHost(), claudeHome: URL(fileURLWithPath: "/tmp/admiral-none"),
                                 executablePath: "/bin/echo", supportDir: base)
        manager.register(AgentSession(callsign: "alice", cwd: "/a", claudeSessionID: sid, token: "A"),
                         handle: FakeTerminalHost.Handle(pid: 1))
        server = MCPServer(bridge: BridgeCore(manager: manager))
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: base) }

    private func call(_ args: [String: Any]) -> [String: Any] {
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                      "params": ["name": "AskUserQuestion", "arguments": args]]
        let data = server.handle(requestData: try! JSONSerialization.data(withJSONObject: request),
                                 sessionToken: "A")
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return obj?["result"] as? [String: Any] ?? [:]
    }

    private let questions: [String: Any] = ["questions": [[
        "question": "Pick a color?", "header": "Color", "multiSelect": false,
        "options": [["label": "Red", "description": ""], ["label": "Green", "description": ""]],
    ]]]

    /// The mirror advertises the built-in's input: questions[] of question/header/multiSelect/options.
    func testMirrorAdvertisesTheBuiltInsSchema() throws {
        let tool = try XCTUnwrap(MCPServer.tools.first { $0["name"] as? String == "AskUserQuestion" })
        let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
        XCTAssertEqual(schema["required"] as? [String], ["questions"])
        let items = try XCTUnwrap(((schema["properties"] as? [String: Any])?["questions"] as? [String: Any])?["items"] as? [String: Any])
        XCTAssertEqual(Set((items["properties"] as? [String: Any])?.keys.map { $0 } ?? []),
                       ["question", "header", "multiSelect", "options"])
    }

    func testMirrorPutsTheQuestionsInTheChatAndReturnsAtOnce() {
        ChatLedger.setMode(.chat, base: base, session: sid)
        let result = call(questions)
        XCTAssertEqual(result["isError"] as? Bool, false)
        let chat = ChatFolder.fold(ChatLedger.read(base: base, session: sid))
        XCTAssertEqual(chat.openAsk?.questions.first?.question, "Pick a color?")
        XCTAssertEqual(chat.openAsk?.questions.first?.options.map(\.label), ["Red", "Green"])
    }

    func testMirrorRefusesInATerminalModeTab() {
        ChatLedger.setMode(.terminal, base: base, session: sid)
        let result = call(questions)
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertNil(ChatFolder.fold(ChatLedger.read(base: base, session: sid)).openAsk)
    }

    func testMirrorRejectsMissingQuestions() {
        XCTAssertEqual(call([:])["isError"] as? Bool, true)
    }

    /// The composer types, never pastes; newlines ride as LF, which claude's prompt takes as a
    /// newline (probed: a three-line message arrives with "\n" and no backslash). No CR may
    /// survive — one mid-message submits it early.
    func testTypedTextKeepsNewlinesAsLineFeeds() {
        let typed = SessionManager.typedText("Line one.\nLine two\r\nthree\rfour\n")
        XCTAssertEqual(typed, "Line one.\nLine two\nthree\nfour")
        XCTAssertFalse(typed.contains("\r"))
        XCTAssertFalse(typed.contains("\u{1b}[200~"), "never bracket-pasted")
    }

    /// Chat exists only for managed claude tabs; a bash tab (`zsh -il`, no session id) is
    /// always a terminal — the app's view mode keys off exactly this.
    func testOnlyManagedAgentTypesHaveAChat() {
        XCTAssertTrue(AgentType.claudeCode.isManaged)
        let bash = AgentType(id: "bash", displayName: "Bash", executableName: "zsh",
                             defaultArgs: ["-il"], symbolName: "terminal")
        XCTAssertFalse(bash.isManaged)
    }

    func testInjectMarksThePromptAsAdmirals() {
        manager.inject(manager.sessions[0].id, text: "PR #5 checks passed", source: "pr-watch")
        XCTAssertEqual(ChatLedger.consumeInjected(prompt: "PR #5 checks passed", base: base, session: sid),
                       "pr-watch")
    }

    /// A long hail's body reaches claude as a paste, so its prompt comes back with the body
    /// wrapped in `<pasted_content>` tags. It is still Admiral's.
    func testAPastedPromptIsStillAdmirals() {
        let body = String(repeating: "step\n", count: 400)
        manager.inject(manager.sessions[0].id,
                       prompt: TerminalPrompt(typedBefore: "@bob: ", pasted: body, typedAfter: " [no reply needed]"),
                       source: "hail")
        let submitted = "@bob: \n\n<pasted_content id=\"ab12\">\n\(body)\n</pasted_content id=\"ab12\">\n\n [no reply needed]"
        XCTAssertEqual(ChatLedger.consumeInjected(prompt: submitted, base: base, session: sid), "hail")
    }
}
