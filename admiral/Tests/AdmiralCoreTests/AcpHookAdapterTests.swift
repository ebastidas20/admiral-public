import XCTest
@testable import AdmiralCore

final class AcpHookAdapterTests: XCTestCase {
    private var base: URL!
    private let token = "acp-tok"
    private let sid = "acp-sid"

    override func setUp() {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-hooks-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: base) }

    /// Answers git like a repo at `/workspace/repo` on `main`; records every argv it was given.
    private final class FakeRunner: CommandRunner, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [[String]] = []
        var calls: [[String]] { lock.withLock { _calls } }

        func run(_ argv: [String], cwd: String?, timeout: TimeInterval) -> (code: Int32, stdout: String)? {
            lock.withLock { _calls.append(argv) }
            if argv.contains("rev-parse") { return (0, "/workspace/repo\n") }
            if argv.contains("symbolic-ref") { return (0, "main\n") }
            return (1, "")
        }
    }

    private func adapter(runner: CommandRunner? = nil) -> AcpHookAdapter {
        AcpHookAdapter(base: base, token: token, sessionID: sid, cwd: "/workspace/repo", runner: runner)
    }

    private func openGoal() {
        guard case let .success(goals) = SessionGoals.make(from: ["ship it"]) else {
            return XCTFail("fixture must be valid")
        }
        GoalsStore(base: base).set(goals, forSession: sid)
    }

    private var schema: JSONValue {
        try! JSONDecoder().decode(JSONValue.self, from: Data(#"{"type":"object"}"#.utf8))
    }

    private func reason(ofStopJSON json: String) -> String? {
        let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
        return obj?["reason"] as? String
    }

    // MARK: - UserPromptSubmit

    func testBeforePromptPrependsGoalsReminderWhenGoalsOpen() async {
        openGoal()
        let goals = GoalsStore(base: base).goals(forSession: sid)
        let out = await adapter().beforePrompt("do the thing")
        XCTAssertEqual(out, GoalsReminder.context(for: goals) + "\n\ndo the thing")
    }

    /// With no goals the dispatcher invites the session to set some (every prompt carries a
    /// reminder) — the adapter passes that through rather than deciding otherwise.
    func testBeforePromptWithNoGoalsCarriesTheInvitation() async {
        let out = await adapter().beforePrompt("hi")
        XCTAssertEqual(out, GoalsReminder.context(for: nil) + "\n\nhi")
    }

    /// When the dispatcher adds no context (goals open, the full reminder already sent), the
    /// prompt goes out exactly as typed.
    func testBeforePromptUnchangedWhenDispatcherAddsNoContext() async {
        openGoal()
        let a = adapter()
        _ = await a.beforePrompt("first")
        let out = await a.beforePrompt("second")
        XCTAssertEqual(out, "second")
    }

    // MARK: - Stop

    func testAfterTurnReturnsGoalReviewOncePerPrompt() async {
        openGoal()
        let goals = GoalsStore(base: base).goals(forSession: sid)!
        let review = reason(ofStopJSON: GoalsReminder.stopReviewJSON(for: goals))
        XCTAssertNotNil(review)
        let a = adapter()
        _ = await a.beforePrompt("go")
        let first = await a.afterTurn(lastAssistantMessage: "did some")
        XCTAssertEqual(first, review)
        let second = await a.afterTurn(lastAssistantMessage: "still")
        XCTAssertNil(second, "one review block per prompt")
        _ = await a.beforePrompt("again")
        let third = await a.afterTurn(lastAssistantMessage: "more")
        XCTAssertEqual(third, review, "a new prompt re-arms the review")
    }

    func testAfterTurnReturnsStructuredOutputBlockWhenArmed() async {
        StructuredOutputStore.write(.init(schema: schema, delivery: .jsonText), base: base, token: token)
        let expected = reason(ofStopJSON: StopInstruction.blockJSON(schema: schema, type: .api))
        let a = adapter()
        for n in 1...StructuredOutputState.maxBlocks {
            let out = await a.afterTurn(lastAssistantMessage: "answer \(n)")
            XCTAssertEqual(out, expected, "block \(n)")
        }
        let exhausted = await a.afterTurn(lastAssistantMessage: "no")
        XCTAssertNil(exhausted)
        XCTAssertEqual(StructuredOutputStore.read(base: base, token: token)?.status, .failed)
    }

    func testAfterTurnNilWhenNothingOwed() async {
        let out = await adapter().afterTurn(lastAssistantMessage: "done")
        XCTAssertNil(out)
    }

    // MARK: - PostToolUse

    func testToolCallEditRecordsTouchedRepoViaRunner() async {
        let runner = FakeRunner()
        let a = adapter(runner: runner)
        await a.onToolCall(.toolCall(id: "t1", title: "Edit a.swift", kind: "edit", status: "pending",
                                     rawInput: nil, locations: ["/workspace/repo/Sources/a.swift"]))
        XCTAssertTrue(TouchedReposReader.read(base: base, token: token).isEmpty, "not written until completed")
        await a.onToolCall(.toolCallUpdate(id: "t1", status: "completed", content: nil, locations: []))
        let repos = TouchedReposReader.read(base: base, token: token)
        XCTAssertEqual(repos.map(\.root), ["/workspace/repo"])
        XCTAssertEqual(repos.first?.branches, ["main"])
        XCTAssertEqual(repos.first?.filesWritten, 1)
        XCTAssertEqual(repos.first?.insideSessionRoot, true)
        XCTAssertTrue(runner.calls.contains(["git", "-C", "/workspace/repo/Sources", "rev-parse", "--show-toplevel"]),
                      "\(runner.calls)")
        // A later update for the same call records nothing more.
        await a.onToolCall(.toolCallUpdate(id: "t1", status: "completed", content: nil,
                                           locations: ["/workspace/repo/Sources/a.swift"]))
        XCTAssertEqual(TouchedReposReader.read(base: base, token: token).first?.filesWritten, 1)
    }

    /// The update can land first (the controller hands each to its own Task) — the call is
    /// recorded once both halves are known, in either order.
    func testToolCallEditRecordedWhenUpdateArrivesBeforeKind() async {
        let a = adapter(runner: FakeRunner())
        await a.onToolCall(.toolCallUpdate(id: "t2", status: "completed", content: nil,
                                           locations: ["/workspace/repo/b.swift"]))
        await a.onToolCall(.toolCall(id: "t2", title: "Edit", kind: "edit", status: nil,
                                     rawInput: nil, locations: []))
        XCTAssertEqual(TouchedReposReader.read(base: base, token: token).map(\.root), ["/workspace/repo"])
    }

    func testNonEditOrFailedToolCallRecordsNothing() async {
        let a = adapter(runner: FakeRunner())
        await a.onToolCall(.toolCall(id: "r", title: "Read", kind: "read", status: "completed",
                                     rawInput: nil, locations: ["/workspace/repo/a"]))
        await a.onToolCall(.toolCall(id: "f", title: "Edit", kind: "edit", status: "failed",
                                     rawInput: nil, locations: ["/workspace/repo/a"]))
        XCTAssertTrue(TouchedReposReader.read(base: base, token: token).isEmpty)
    }

    func testToolCallSkippedWithoutRunner() async {
        await adapter(runner: nil).onToolCall(.toolCall(id: "t", title: "Edit", kind: "edit", status: "completed",
                                                        rawInput: nil, locations: ["/workspace/repo/a"]))
        XCTAssertTrue(TouchedReposReader.read(base: base, token: token).isEmpty)
    }

    // MARK: - SessionStart compact

    func testCompactionForgetsReminderMarker() async {
        openGoal()
        let full = GoalsReminder.context(for: GoalsStore(base: base).goals(forSession: sid))
        let a = adapter()
        _ = await a.beforePrompt("one")
        let quiet = await a.beforePrompt("two")
        XCTAssertEqual(quiet, "two")
        await a.onCompaction()
        let again = await a.beforePrompt("three")
        XCTAssertEqual(again, full + "\n\nthree")
    }
}
