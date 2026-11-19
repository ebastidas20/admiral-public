import XCTest
@testable import AdmiralCore

@MainActor
final class TranscriptMirrorTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-\(UUID().uuidString)")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func make() -> (TranscriptMirror, URL) {
        let url = TranscriptMirror.url(base: dir, session: "s1")
        return (TranscriptMirror(url: url, sessionID: "s1", cwd: "/workspace"), url)
    }

    private func lines(_ url: URL) -> [String] {
        let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return raw.split(separator: "\n").map(String.init)
    }

    func testUrlLayout() {
        XCTAssertEqual(TranscriptMirror.url(base: dir, session: "s1").path, dir.path + "/acp/s1.jsonl")
    }

    func testPromptAndReplyParseAsOneTurn() {
        let (m, url) = make()
        m.userPrompt("hi")
        m.apply(.agentMessage("Hel"))
        m.apply(.agentMessage("lo"))
        m.endTurn()
        let turns = TranscriptParser.parse(lines: lines(url)).turns
        XCTAssertEqual(turns.count, 2)
        guard case let .user(_, user) = turns[0], case let .assistant(_, md, _) = turns[1] else {
            return XCTFail("unexpected turns \(turns)")
        }
        XCTAssertEqual(user, "hi")
        XCTAssertEqual(md, "Hello")
    }

    func testToolCallAndResultParseAsATool() {
        let (m, url) = make()
        m.apply(.toolCall(id: "t1", title: "Read file", kind: "read", status: "pending",
                          rawInput: .object(["file_path": .string("/workspace/a")]), locations: []))
        m.apply(.toolCallUpdate(id: "t1", status: "completed", content: "x", locations: []))
        let turns = TranscriptParser.parse(lines: lines(url)).turns
        guard case let .tool(id, name, params, result, state) = turns.first else { return XCTFail("\(turns)") }
        XCTAssertEqual(id, "t1")
        XCTAssertEqual(name, "Read")
        XCTAssertTrue(params.contains("/workspace/a"))
        XCTAssertEqual(result, "x")
        XCTAssertEqual(state, .success)
    }

    /// claude-agent-acp opens every tool call with `rawInput: {}` and sends the input on the
    /// first `tool_call_update` (probed on 0.100.0 in Task 12): the Chat's card must show the
    /// command, and show it while the call still runs — not `{}` for the whole session.
    func testToolInputArrivingOnAnUpdateReachesTheToolUse() {
        let (m, url) = make()
        m.apply(.toolCall(id: "t1", title: "Terminal", kind: "execute", status: "pending",
                          rawInput: .object([:]), locations: []))
        m.apply(.toolCallUpdate(id: "t1", status: nil, content: nil, locations: [],
                                rawInput: .object(["command": .string("echo bash-ok")])))
        XCTAssertEqual(lines(url).count, 1, "the running call is shown once its input is known")
        m.apply(.toolCallUpdate(id: "t1", status: "completed", content: "bash-ok", locations: []))
        guard case let .tool(id, name, params, result, _) = TranscriptParser.parse(lines: lines(url)).turns.first
        else { return XCTFail("\(lines(url))") }
        XCTAssertEqual(id, "t1")
        XCTAssertEqual(name, "Bash")
        XCTAssertTrue(params.contains("echo bash-ok"), params)
        XCTAssertEqual(result, "bash-ok")
    }

    /// A call whose input never comes still lands — with what it has, ahead of what followed it.
    func testToolCallWithoutInputStillLandsInOrder() {
        let (m, url) = make()
        m.apply(.toolCall(id: "t1", title: "x", kind: "execute", status: "pending",
                          rawInput: .object([:]), locations: []))
        m.apply(.agentMessage("after"))
        m.endTurn()
        let turns = TranscriptParser.parse(lines: lines(url)).turns
        XCTAssertEqual(turns.count, 2, "\(turns)")
        guard case .tool = turns.first, case let .assistant(_, md, _) = turns.last else { return XCTFail("\(turns)") }
        XCTAssertEqual(md, "after")
    }

    /// The tool_result line's top-level `toolUseResult`, as real Claude transcripts carry it.
    private func toolUseResult(_ url: URL) throws -> [String: Any]? {
        for l in lines(url) {
            let obj = try JSONSerialization.jsonObject(with: Data(l.utf8)) as? [String: Any]
            if let result = obj?["toolUseResult"] as? [String: Any] { return result }
        }
        return nil
    }

    func testDiffUpdateGivesTheResultAClaudeShapedEdit() throws {
        let (m, url) = make()
        m.apply(.toolCall(id: "t1", title: "Edit a.swift", kind: "edit", status: "pending",
                          rawInput: .object(["file_path": .string("/p/a.swift")]), locations: []))
        m.apply(.toolCallUpdate(id: "t1", status: nil, content: nil, locations: [],
                                items: [.diff(path: "/p/a.swift", oldText: "x", newText: "y")]))
        // claude-agent-acp's final whole-file diff comes last, and wins.
        m.apply(.toolCallUpdate(id: "t1", status: nil, content: nil, locations: [],
                                items: [.diff(path: "/p/a.swift", oldText: "a\n", newText: "b\n")]))
        m.apply(.toolCallUpdate(id: "t1", status: "completed", content: nil, locations: []))
        let result = try XCTUnwrap(toolUseResult(url))
        XCTAssertEqual(result["filePath"] as? String, "/p/a.swift")
        XCTAssertEqual(result["type"] as? String, "update")
        XCTAssertEqual(result["oldString"] as? String, "a\n")
        XCTAssertEqual(result["newString"] as? String, "b\n")
    }

    func testANewFileDiffIsACreate() throws {
        let (m, url) = make()
        m.apply(.toolCall(id: "t1", title: "Write", kind: "edit", status: nil, rawInput: nil, locations: []))
        m.apply(.toolCallUpdate(id: "t1", status: "completed", content: "done", locations: [],
                                items: [.diff(path: "/p/n.swift", oldText: nil, newText: "x"), .text("done")]))
        let result = try XCTUnwrap(toolUseResult(url))
        XCTAssertEqual(result["type"] as? String, "create")
        XCTAssertEqual(result["oldString"] as? String, "")
    }

    func testTerminalOutputAccumulatesIntoStdout() throws {
        let (m, url) = make()
        m.apply(.toolCall(id: "t1", title: "ls", kind: "execute", status: "pending",
                          rawInput: .object(["command": .string("ls")]), locations: []))
        m.apply(.toolCallUpdate(id: "t1", status: "in_progress", content: nil, locations: [],
                                items: [.terminal(id: "t1")]))
        m.apply(.terminalOutput(toolCallID: "t1", data: "a"))
        m.apply(.terminalOutput(toolCallID: "t1", data: "b"))
        m.apply(.terminalExit(toolCallID: "t1", exitCode: 0))
        m.apply(.toolCallUpdate(id: "t1", status: "completed", content: nil, locations: []))
        XCTAssertEqual(try toolUseResult(url)?["stdout"] as? String, "ab")
    }

    func testATerminalCallWithoutOutputFallsBackToItsText() throws {
        let (m, url) = make()
        m.apply(.toolCall(id: "t1", title: "ls", kind: "execute", status: nil, rawInput: nil, locations: []))
        m.apply(.toolCallUpdate(id: "t1", status: "completed", content: "plain", locations: [],
                                items: [.terminal(id: "t1"), .text("plain")]))
        XCTAssertEqual(try toolUseResult(url)?["stdout"] as? String, "plain")
    }

    func testAPlainResultHasNoToolUseResult() throws {
        let (m, url) = make()
        m.apply(.toolCall(id: "t1", title: "Read", kind: "read", status: nil, rawInput: nil, locations: []))
        m.apply(.toolCallUpdate(id: "t1", status: "completed", content: "x", locations: [], items: [.text("x")]))
        XCTAssertNil(try toolUseResult(url))
    }

    /// End to end on the ACP Chat: the mirror's lines become tool cards only when asked for.
    func testChatHistoryShowsMirroredToolsOnlyWhenAsked() {
        let (m, url) = make()
        m.userPrompt("run it")
        m.apply(.toolCall(id: "t1", title: "ls", kind: "execute", status: "pending",
                          rawInput: .object(["command": .string("ls -la")]), locations: []))
        m.apply(.terminalOutput(toolCallID: "t1", data: "file\n"))
        m.apply(.toolCallUpdate(id: "t1", status: "completed", content: nil, locations: []))
        m.endTurn()
        let plain = ChatHistory.live(base: dir, session: "s1", transcriptPath: url.path).items
        XCTAssertEqual(plain.count, 1)
        let items = ChatHistory.live(base: dir, session: "s1", transcriptPath: url.path, tools: true).items
        guard items.count == 2, case let .tool(_, tool, _) = items[1] else { return XCTFail("\(items)") }
        XCTAssertEqual(tool.name, "Bash")
        XCTAssertEqual(tool.title, "ls -la")
        XCTAssertEqual(tool.status, .completed)
        XCTAssertEqual(tool.detail, .output("file\n"))
    }

    func testFailedToolCallIsError() {
        let (m, url) = make()
        m.apply(.toolCall(id: "t1", title: "Run", kind: "execute", status: nil, rawInput: nil, locations: []))
        m.apply(.toolCallUpdate(id: "t1", status: "failed", content: "boom", locations: []))
        guard case let .tool(_, _, _, _, state) = TranscriptParser.parse(lines: lines(url)).turns.first else {
            return XCTFail()
        }
        XCTAssertEqual(state, .error)
    }

    func testChunkAfterToolStartsNewAssistantLine() {
        let (m, url) = make()
        m.apply(.agentMessage("before"))
        m.apply(.toolCall(id: "t1", title: "x", kind: nil, status: nil, rawInput: nil, locations: []))
        m.apply(.agentMessage("after"))
        m.endTurn()
        XCTAssertEqual(lines(url).count, 3)
        let turns = TranscriptParser.parse(lines: lines(url)).turns
        XCTAssertEqual(turns.count, 3)
    }

    func testPlanUpdateFoldsIntoPlanModel() {
        let (m, url) = make()
        m.apply(.plan([
            AcpPlanEntry(content: "a", status: "completed", priority: nil),
            AcpPlanEntry(content: "b", status: "pending", priority: nil),
        ]))
        let plan = TranscriptParser.plan(lines: lines(url))
        XCTAssertEqual(plan?.progress.done, 1)
        XCTAssertEqual(plan?.progress.total, 2)
    }

    func testTurnCaptureSeesTheReply() throws {
        let (m, url) = make()
        m.userPrompt("hi")
        m.apply(.agentMessage("Hello"))
        m.endTurn()
        let data = try Data(contentsOf: url)
        XCTAssertEqual(TurnCapture.capture(data, fromOffset: 0).text, "Hello")
        XCTAssertEqual(TurnCapture.userTexts(in: data), ["hi"])
    }

    func testChatHistoryShowsPromptAndReply() {
        let (m, url) = make()
        m.userPrompt("hi")
        m.apply(.agentMessage("Hello"))
        m.endTurn()
        let items = ChatHistory.live(base: dir, session: "s1", transcriptPath: url.path).items
        XCTAssertEqual(items.count, 2)
        guard case let .prompt(_, p, _, _) = items[0], case let .reply(_, r, _) = items[1] else {
            return XCTFail("\(items)")
        }
        XCTAssertEqual(p, "hi")
        XCTAssertEqual(r, "Hello")
    }

    /// What Chat draws for the mirror: each item as "kind: text".
    private func chat(_ url: URL) -> [String] {
        ChatHistory.live(base: dir, session: "s1", transcriptPath: url.path).items.map { item in
            switch item {
            case let .prompt(_, text, _, _): "prompt: \(text)"
            case let .reply(_, text, _): "reply: \(text)"
            case let .notice(_, text, _): "notice: \(text)"
            default: "other"
            }
        }
    }

    /// A slash command shows as a command, as in a claude tab; a path is still a prompt.
    func testSlashCommandIsWrittenAsACommand() {
        let (m, url) = make()
        m.userPrompt("/compact keep the plan")
        m.endTurn()
        m.commandFinished(succeeded: true)
        m.userPrompt("/path/to/file is broken")
        m.endTurn()
        XCTAssertEqual(chat(url), ["notice: /compact keep the plan", "prompt: /path/to/file is broken"])
    }

    /// A `/clear` the agent ended normally hides everything older; one that failed hides nothing.
    func testClearHidesTheConversationBeforeIt() {
        let (m, url) = make()
        m.userPrompt("hi")
        m.apply(.agentMessage("Hello"))
        m.endTurn()
        m.userPrompt("/clear")
        m.endTurn()
        m.commandFinished(succeeded: false)
        XCTAssertEqual(chat(url), ["prompt: hi", "reply: Hello", "notice: /clear"])

        m.userPrompt("/clear")
        m.endTurn()
        m.commandFinished(succeeded: true)
        m.userPrompt("again")
        m.endTurn()
        m.commandFinished(succeeded: true)
        XCTAssertEqual(chat(url), ["notice: Conversation cleared", "prompt: again"])
        let page = ChatHistory.page(base: dir, session: "s1", transcriptPath: url.path, before: nil)
        XCTAssertFalse(page.hasMore, "no older page loads past a clear")
        XCTAssertEqual(page.items.count, 2)
    }

    /// A finished compaction and a failed one each say so; one in progress says nothing.
    func testCompactionOutcomesAreNotices() {
        let (m, url) = make()
        m.apply(.compaction(status: "in_progress", error: nil))
        m.apply(.compaction(status: "failed", error: "Not enough messages to compact."))
        m.apply(.compaction(status: "completed", error: nil))
        XCTAssertEqual(chat(url), [
            "notice: Compaction failed: Not enough messages to compact.", "notice: Conversation compacted",
        ])
    }

    /// A turn the agent starts by itself (a background task finished) has no prompt in flight, so
    /// no `endTurn()`: its reply must land when the agent reports the query's cost, not when the
    /// next prompt happens to flush it.
    func testQueryFinishedLandsAnAgentStartedReply() {
        let (m, url) = make()
        m.apply(.agentMessage("Deploy still running."))
        XCTAssertEqual(chat(url), [])
        m.apply(.queryFinished)
        XCTAssertEqual(chat(url), ["reply: Deploy still running."])
    }

    func testReplayedUserMessageIsAUserLine() throws {
        let (m, url) = make()
        m.apply(.userMessage("old"))
        XCTAssertEqual(TurnCapture.userTexts(in: try Data(contentsOf: url)), ["old"])
    }

    func testEveryLineIsSingleLineJSON() throws {
        let (m, url) = make()
        m.userPrompt("multi\nline \"quoted\" /path")
        m.apply(.agentThought("think\nhard"))
        m.apply(.agentMessage("a\nb"))
        m.apply(.toolCall(id: "t", title: "T", kind: nil, status: "completed", rawInput: nil, locations: []))
        m.endTurn()
        let all = lines(url)
        XCTAssertEqual(all.count, 4)
        for l in all {
            let obj = try JSONSerialization.jsonObject(with: Data(l.utf8)) as? [String: Any]
            XCTAssertEqual(obj?["sessionId"] as? String, "s1")
            XCTAssertEqual(obj?["cwd"] as? String, "/workspace")
            XCTAssertNotNil(obj?["timestamp"])
        }
    }

    func testEndTurnTwiceWritesOneAssistantLine() {
        let (m, url) = make()
        m.apply(.agentMessage("Hello"))
        m.endTurn()
        m.endTurn()
        XCTAssertEqual(lines(url).count, 1)
    }

    func testDroppingMirrorFlushesPendingText() {
        let url = TranscriptMirror.url(base: dir, session: "s1")
        var m: TranscriptMirror? = TranscriptMirror(url: url, sessionID: "s1", cwd: "/")
        m?.apply(.agentMessage("partial"))
        m = nil
        XCTAssertEqual(TurnCapture.capture((try? Data(contentsOf: url)) ?? Data(), fromOffset: 0).text, "partial")
    }

    func testThoughtAndTextKeepTheirOrder() throws {
        let (m, url) = make()
        m.apply(.agentThought("t1"))
        m.apply(.agentThought("a"))
        m.apply(.agentMessage("x1"))
        m.apply(.agentThought("t2"))
        m.apply(.agentMessage("x2"))
        m.endTurn()
        let obj = try JSONSerialization.jsonObject(with: Data(lines(url)[0].utf8)) as? [String: Any]
        let blocks = (obj?["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        XCTAssertEqual(blocks.map { $0["type"] as? String }, ["thinking", "text", "thinking", "text"])
        XCTAssertEqual(blocks[0]["thinking"] as? String, "t1a")
        XCTAssertEqual(blocks[3]["text"] as? String, "x2")
    }

    func testUnwritablePathDoesNotCrash() {
        let m = TranscriptMirror(url: URL(fileURLWithPath: "/dev/null/x/y.jsonl"), sessionID: "s", cwd: "/")
        m.userPrompt("hi")
        m.endTurn()
    }
}
