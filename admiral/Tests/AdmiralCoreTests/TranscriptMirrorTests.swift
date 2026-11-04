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
