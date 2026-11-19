import XCTest
@testable import AdmiralCore

/// The chat timeline: the transcript supplies the conversation (every prompt, every agent
/// message, the harness's notices), the ledger adds questions, permission prompts and who
/// typed a prompt, and older pages come in a page at a time before a cursor.
final class ChatHistoryTests: XCTestCase {
    private var base: URL!
    private var transcript: URL!
    private let sid = "hist-0000-1111"

    override func setUp() {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("hist-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        transcript = base.appendingPathComponent("t.jsonl")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: base) }

    private func ts(_ minute: Int) -> String { String(format: "2026-09-21T10:%02d:00.000Z", minute) }

    private func user(_ content: Any, _ minute: Int, extra: [String: Any] = [:]) -> [String: Any] {
        ["type": "user", "timestamp": ts(minute), "message": ["role": "user", "content": content]]
            .merging(extra) { $1 }
    }
    private func assistant(_ blocks: [[String: Any]], _ minute: Int, extra: [String: Any] = [:]) -> [String: Any] {
        ["type": "assistant", "timestamp": ts(minute), "message": ["role": "assistant", "content": blocks]]
            .merging(extra) { $1 }
    }
    private func say(_ text: String) -> [String: Any] { ["type": "text", "text": text] }
    private func write(_ lines: [[String: Any]]) {
        let text = lines.map { String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
            .joined(separator: "\n") + "\n"
        try! text.write(to: transcript, atomically: true, encoding: .utf8)
    }
    private func texts(_ items: [ChatItem]) -> [String] {
        items.map { item in
            switch item {
            case let .prompt(_, text, _, _): return "you: \(text)"
            case let .reply(_, text, _): return "agent: \(text)"
            case let .notice(_, text, _): return "notice: \(text)"
            case .ask: return "ask"
            case .needs: return "needs"
            case let .tool(_, tool, _): return "tool: \(tool.name) \(tool.status.rawValue)"
            }
        }
    }
    private var live: [String] {
        texts(ChatHistory.live(base: base, session: sid, transcriptPath: transcript.path).items)
    }

    /// Every message the agent sent shows — the narration before its tool calls as well as the
    /// end-of-turn answer — while tool calls, results and thinking don't.
    func testEveryAgentMessageShowsNotJustTheLast() {
        write([
            user("fix the comet", 0),
            assistant([say("Let me look at the status refresh."),
                       ["type": "tool_use", "id": "t1", "name": "Read", "input": [:]]], 1),
            user([["type": "tool_result", "tool_use_id": "t1", "content": "…"]], 2),
            assistant([["type": "thinking", "thinking": "hmm"]], 3),
            assistant([say("Found it: the pid match is stale.")], 4),
            assistant([say("Fixed. Tests pass.")], 5),
        ])
        XCTAssertEqual(live, ["you: fix the comet", "agent: Let me look at the status refresh.",
                              "agent: Found it: the pid match is stale.", "agent: Fixed. Tests pass."])
    }

    private func toolUse(_ id: String, _ name: String, _ input: [String: Any]) -> [String: Any] {
        ["type": "tool_use", "id": id, "name": name, "input": input]
    }
    private func toolResult(_ id: String, _ content: Any, error: Bool = false) -> [String: Any] {
        ["type": "tool_result", "tool_use_id": id, "content": content, "is_error": error]
    }
    private func tools() -> [ChatTool] {
        ChatHistory.live(base: base, session: sid, transcriptPath: transcript.path, tools: true).items.compactMap {
            if case let .tool(_, tool, _) = $0 { return tool }
            return nil
        }
    }

    private func writeBashRun() {
        write([
            user("list files", 0),
            assistant([toolUse("t1", "Bash", ["command": "ls -la"])], 1),
            user([toolResult("t1", "")], 2, extra: ["toolUseResult": ["stdout": "a.swift\nb.swift"]]),
            assistant([say("Two files.")], 3),
        ])
    }

    /// The ACP Chat (`tools: true`) shows each tool call as a card: opened by its tool_use,
    /// completed by its tool_result, with the command's output from `toolUseResult.stdout`.
    func testToolsShowAsCardsWhenAsked() {
        writeBashRun()
        let items = ChatHistory.live(base: base, session: sid, transcriptPath: transcript.path, tools: true).items
        XCTAssertEqual(texts(items), ["you: list files", "tool: Bash completed", "agent: Two files."])
        guard case let .tool(id, tool, ts) = items[1] else { return XCTFail() }
        XCTAssertEqual(id, -2, "the tool_use line's id")
        XCTAssertEqual(ts, self.ts(1))
        XCTAssertEqual(tool.id, "t1")
        XCTAssertEqual(tool.title, "ls -la")
        XCTAssertEqual(tool.detail, .output("a.swift\nb.swift"))
    }

    /// Guard: the PTY Chat is unchanged — no tool cards unless asked for (the default).
    func testNoToolCardsByDefault() {
        writeBashRun()
        XCTAssertEqual(live, ["you: list files", "agent: Two files."])
        let page = ChatHistory.page(base: base, session: sid, transcriptPath: transcript.path, before: nil)
        XCTAssertEqual(texts(page.items), ["you: list files", "agent: Two files."])
    }

    func testToolStatusAndDetail() {
        write([
            assistant([toolUse("r", "Bash", ["command": "make"])], 0),
            assistant([toolUse("f", "Bash", ["command": "false"])], 1),
            user([toolResult("f", [["type": "text", "text": "```console\nboom\n```"]], error: true)], 2),
            assistant([toolUse("e", "Edit", ["file_path": "/p/a.swift"])], 3),
            user([toolResult("e", "ok")], 4, extra: ["toolUseResult": [
                "filePath": "/p/a.swift", "oldString": "a\n", "newString": "b\n", "type": "update"]]),
            assistant([toolUse("w", "Write", ["file_path": "/p/n.swift"])], 5),
            user([toolResult("w", "")], 6, extra: ["toolUseResult": [
                "filePath": "/p/n.swift", "oldString": "", "newString": "x\n", "type": "create"]]),
            assistant([toolUse("p", "TodoWrite", ["todos": []])], 7),
            assistant([toolUse("n", "Read", [:])], 8),
            user([toolResult("n", "")], 9),
        ])
        let all = tools()
        XCTAssertEqual(all.map(\.id), ["r", "f", "e", "w", "n"], "TodoWrite stays a plan, never a card")
        XCTAssertEqual(all[0].status, .running, "no result in the window yet")
        XCTAssertEqual(all[0].detail, .none)
        XCTAssertEqual(all[1].status, .failed)
        XCTAssertEqual(all[1].detail, .output("boom"), "a whole-text console fence is stripped")
        XCTAssertEqual(all[2].status, .completed)
        XCTAssertEqual(all[2].detail, .diff(path: "/p/a.swift", hunks: LineDiff.hunks(old: "a\n", new: "b\n"),
                                            created: false))
        guard case let .diff(_, _, created) = all[3].detail else { return XCTFail("\(all[3])") }
        XCTAssertTrue(created)
        XCTAssertEqual(all[4].title, "Read", "no input: the tool's name")
        XCTAssertEqual(all[4].detail, .none)
    }

    /// The ledger records the same Stop reply the transcript holds; it must not show twice.
    func testALedgerReplyIsNotShownTwice() {
        write([user("hello", 0), assistant([say("Hello!")], 1)])
        ChatLedger.append(ChatEvent(ts: "2026-09-21T10:00:00Z", kind: .prompt, text: "hello"), base: base, session: sid)
        ChatLedger.append(ChatEvent(ts: "2026-09-21T10:01:00Z", kind: .reply, text: "Hello!"), base: base, session: sid)
        XCTAssertEqual(live, ["you: hello", "agent: Hello!"])
    }

    /// The harness's own messages show as notices, in the shapes claude 2.1.280 writes them.
    func testHarnessMessagesAreNotices() {
        write([
            user("Stop hook feedback:\nThere are uncommitted changes.", 0, extra: ["isMeta": true]),
            user("<local-command-caveat>Caveat: The messages below were generated by the user.</local-command-caveat>",
                 1, extra: ["isMeta": true]),
            user("<command-name>/model</command-name>\n<command-message>model</command-message>\n<command-args>opus</command-args>", 2),
            user("<local-command-stdout>Set model to Opus</local-command-stdout>", 3),
            assistant([say("API Error: 500 Request timeout.")], 4, extra: ["isApiErrorMessage": true]),
            user([say("[Request interrupted by user]")], 5),
            user("Summary of the conversation so far…", 6, extra: ["isCompactSummary": true]),
            user("brief for the subagent", 7, extra: ["isSidechain": true]),
        ])
        XCTAssertEqual(live, [
            "notice: Stop hook: There are uncommitted changes.",
            "notice: /model opus",
            "notice: Set model to Opus",
            "notice: API Error: 500 Request timeout.",
            "notice: Interrupted",
            "notice: Conversation compacted",
        ])
    }

    /// The ledger still supplies what only it knows: questions, permission prompts, and which
    /// prompts Admiral typed.
    func testLedgerAddsQuestionsPermissionsAndSources() {
        write([user("go", 0), assistant([say("Waiting for your pick.")], 2), user("Goal check: done?", 4)])
        ChatLedger.append(ChatEvent(ts: "2026-09-21T10:01:00Z", kind: .ask, questions: [
            AskQuestion(question: "Pick?", header: "Pick", options: [AskOption(label: "A"), AskOption(label: "B")]),
        ]), base: base, session: sid)
        ChatLedger.append(ChatEvent(ts: "2026-09-21T10:03:00Z", kind: .needs, text: "Allow Bash?"), base: base, session: sid)
        ChatLedger.markInjected("Goal check: done?", source: "goals", base: base, session: sid)
        ChatLedger.append(ChatEvent(ts: "2026-09-21T10:04:00Z", kind: .prompt, text: "Goal check: done?",
                                    source: "goals"), base: base, session: sid)

        let items = ChatHistory.live(base: base, session: sid, transcriptPath: transcript.path).items
        XCTAssertEqual(texts(items), ["you: go", "ask", "agent: Waiting for your pick.", "needs", "you: Goal check: done?"])
        guard case let .prompt(_, _, source, _) = items.last else { return XCTFail() }
        XCTAssertEqual(source, "goals")
    }

    /// Each page is strictly older than the cursor, the right size, and says when more remain.
    func testPagesWalkBackwardsWithoutOverlap() {
        write((0..<25).flatMap { i in [user("q\(i)", i * 2), assistant([say("a\(i)")], i * 2 + 1)] })
        let first = ChatHistory.page(base: base, session: sid, transcriptPath: transcript.path, before: nil, limit: 20)
        XCTAssertEqual(first.items.count, 20)
        XCTAssertTrue(first.hasMore)
        let second = ChatHistory.page(base: base, session: sid, transcriptPath: transcript.path,
                                      before: first.items.first?.ts, limit: 20)
        XCTAssertEqual(second.items.count, 20)
        XCTAssertTrue(Set(first.items.map(\.id)).isDisjoint(with: second.items.map(\.id)))
        XCTAssertLessThan(ChatHistory.date(second.items.last!.ts)!, ChatHistory.date(first.items.first!.ts)!)
        let last = ChatHistory.page(base: base, session: sid, transcriptPath: transcript.path,
                                    before: second.items.first?.ts, limit: 20)
        XCTAssertEqual(last.items.count, 10)
        XCTAssertFalse(last.hasMore, "the beginning of the conversation")
    }

    /// The live window reads only the transcript's tail, but ids are absolute line numbers,
    /// so an item keeps its identity between the live window and a full-file page.
    func testLiveAndPagedIdsAgree() {
        write((0..<5).flatMap { i in [user("q\(i)", i * 2), assistant([say("a\(i)")], i * 2 + 1)] })
        let tail = ChatHistory.transcriptEvents(path: transcript.path, tail: 2).map(\.id)
        let full = ChatHistory.transcriptEvents(path: transcript.path, tail: nil).map(\.id)
        XCTAssertEqual(Array(full.suffix(tail.count)), tail)
    }

    func testTaskNotificationInHistoryIsANotice() {
        write([user("<task-notification>\n<status>stopped</status>\n<summary>Shell died</summary>\n</task-notification>", 0)])
        XCTAssertEqual(live, ["notice: Shell died (stopped)"])
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
    private let posix = Locale(identifier: "en_US_POSIX")
    /// Foundation puts a narrow no-break space before AM/PM; compare on plain spaces.
    private func plain(_ s: String) -> String { s.replacingOccurrences(of: "\u{202F}", with: " ") }

    /// A day divider names the day: Today, Yesterday, else weekday and date (+ year when not
    /// this one). Transcript timestamps carry milliseconds and must parse too.
    func testDayLabels() {
        let now = ChatHistory.date("2026-09-23T15:00:00Z")!
        func day(_ iso: String) -> String { ChatHistory.dayLabel(iso, now: now, calendar: utc, locale: posix) }
        XCTAssertEqual(day("2026-09-23T01:00:00.123Z"), "Today")
        XCTAssertEqual(day("2026-09-22T23:59:00.000Z"), "Yesterday")
        XCTAssertEqual(day("2026-09-21T09:30:00Z"), "Monday, September 21")
        XCTAssertEqual(day("2025-12-31T09:30:00.000Z"), "Wednesday, December 31, 2025")
    }

    /// A divider goes above the first item and above each item that starts a new day —
    /// nowhere else.
    func testDayBreaksFallWhereTheDayChanges() {
        let items: [ChatItem] = [
            .prompt(id: 1, text: "a", source: nil, ts: "2026-09-21T10:00:00.000Z"),
            .reply(id: 2, text: "b", ts: "2026-09-21T10:01:00.000Z"),
            .prompt(id: 3, text: "c", source: nil, ts: "2026-09-22T08:00:00.000Z"),
            .reply(id: 4, text: "d", ts: "2026-09-22T08:05:00Z"),
            .prompt(id: 5, text: "e", source: nil, ts: "2026-09-23T09:00:00.000Z"),
        ]
        XCTAssertEqual(ChatHistory.dayBreaks(items, calendar: utc), [1, 3, 5])
        XCTAssertEqual(ChatHistory.dayBreaks(Array(items.prefix(2)), calendar: utc), [1], "one day, one divider")
    }

    /// Messages show their time of day; the full date and time is their hover text.
    func testTimeAndFullLabels() {
        XCTAssertEqual(plain(ChatHistory.timeLabel("2026-09-21T14:05:27.791Z", calendar: utc, locale: posix)), "2:05 PM")
        XCTAssertEqual(plain(ChatHistory.fullLabel("2026-09-21T14:05:27.791Z", calendar: utc, locale: posix)),
                       "Monday, September 21, 2026 at 2:05 PM")
        XCTAssertEqual(ChatHistory.timeLabel("not a date"), "")
    }

    /// A transcript spanning several days gets one divider per day, each with a non-empty title.
    func testMultiDayTranscriptGetsADividerPerDay() throws {
        // Noon UTC keeps each message on its own local calendar day in any time zone within ±11h.
        let stamp = { (day: Int) in ["timestamp": String(format: "2026-09-%02dT12:00:00.000Z", day)] }
        write([
            user("start", 0, extra: stamp(19)), assistant([say("on it")], 0, extra: stamp(19)),
            user("next", 0, extra: stamp(20)), assistant([say("done")], 0, extra: stamp(20)),
            user("again", 0, extra: stamp(21)), assistant([say("ok")], 0, extra: stamp(21)),
        ])
        let items = ChatFolder.fold(ChatHistory.transcriptEvents(path: transcript.path, tail: nil)).items
        let days = Set(items.compactMap { ChatHistory.date($0.ts) }.map { Calendar.current.startOfDay(for: $0) })
        let breaks = ChatHistory.dayBreaks(items)
        XCTAssertEqual(days.count, 3, "the fixture spans three days")
        XCTAssertEqual(breaks.count, days.count, "one divider per day")
        for item in items where breaks.contains(item.id) {
            XCTAssertFalse(ChatHistory.dayLabel(item.ts).isEmpty, item.ts)
        }
    }

    func testBothTimestampFormatsParse() {
        XCTAssertNotNil(ChatHistory.date("2026-09-21T10:05:00Z"), "ledger")
        XCTAssertNotNil(ChatHistory.date("2026-09-21T10:05:00.123Z"), "transcript")
    }

    /// A run of tool calls is drawn as one tight group: every call after the first in a run
    /// is a follower; anything else, or a day divider, ends the run.
    func testToolRunFollowers() {
        func tool(_ id: Int) -> ChatItem {
            .tool(id: id, tool: ChatTool(id: "t\(id)", name: "Bash", title: "ls"), ts: ts(id))
        }
        let items: [ChatItem] = [tool(1), tool(2), tool(3), .notice(id: 4, text: "n", ts: ts(4)), tool(5), tool(6), tool(7)]
        XCTAssertEqual(ChatHistory.toolRunFollowers(items), [2, 3, 6, 7])
        XCTAssertEqual(ChatHistory.toolRunFollowers(items, dayBreaks: [6]), [2, 3, 7])
    }
}
