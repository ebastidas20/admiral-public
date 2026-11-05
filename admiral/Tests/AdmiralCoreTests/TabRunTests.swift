import XCTest
@testable import AdmiralCore

/// The run lifecycle the Anthropic endpoint and scheduled runs share.
@MainActor
final class TabRunTests: XCTestCase {
    private let config = TabRun.Config(busySeenTimeout: 0.05, turnTimeout: 2, pollInterval: 0.002,
                                       structuredOutputGrace: 1, injectReadyTimeout: 0.05,
                                       injectVerifyTimeout: 0.05, injectMaxAttempts: 3)
    private var path: String!

    override func setUp() {
        path = FileManager.default.temporaryDirectory.appendingPathComponent("tabrun-\(UUID().uuidString).jsonl").path
    }
    override func tearDown() { try? FileManager.default.removeItem(atPath: path) }

    /// The status file can read idle the instant Stop fires, before the hook's block resumes
    /// the turn. With a structured-output slot still armed, that idle is not the end.
    func testAStructuredTurnIsNotDoneWhileItsSlotIsStillArmed() async {
        let backend = ScriptedTabRunBackend(statuses: [.busy, .idle], resolveSlotAfterPolls: 6)
        backend.slot = StructuredOutputState(schema: .object([:]), delivery: .jsonText, blocks: 1)
        _ = await TabRun(backend: backend, config: config)
            .awaitTurn(tabID: UUID(), path: path, fromOffset: 0, slot: .output)
        XCTAssertEqual(backend.slot?.status, .fulfilled)
        XCTAssertGreaterThanOrEqual(backend.polls, 6)
    }

    /// The Stop hook re-arms a fulfilled `output` slot when the run continues (round 2, already
    /// blocked once). The idle that comes with that Stop must not end the turn, and what the
    /// caller reads afterwards is the final round's answer, not the first one's.
    func testAReArmedSlotKeepsTheTurnOpenUntilTheFinalRoundResolves() async {
        let r1 = JSONValue.object(["v": .string("first")])
        let r2 = JSONValue.object(["v": .string("final")])
        let backend = ScriptedTabRunBackend(statuses: [.busy, .idle], resolveSlotAfterPolls: 10_000)
        backend.slot = StructuredOutputState(schema: .object([:]), delivery: .jsonText, status: .fulfilled,
                                             result: r1, round: 1, settled: true)
        backend.onPoll = { polls, slot in
            if polls == 2 {   // the second Stop: re-armed and blocked in one write
                slot = StructuredOutputState(schema: .object([:]), delivery: .jsonText, blocks: 1, round: 2)
            }
            if polls == 9 { slot?.status = .fulfilled; slot?.result = r2 }
        }
        _ = await TabRun(backend: backend, config: config)
            .awaitTurn(tabID: UUID(), path: path, fromOffset: 0, slot: .output)
        XCTAssertGreaterThanOrEqual(backend.polls, 9, "the transient armed round held the turn open")
        XCTAssertEqual(backend.slot?.status, .fulfilled)
        XCTAssertEqual(backend.slot?.round, 2)
        XCTAssertEqual(backend.slot?.result, r2)
    }

    func testAPlainTurnIsDoneAtTheFirstIdleAfterBusy() async {
        let backend = ScriptedTabRunBackend(statuses: [.busy, .idle], resolveSlotAfterPolls: 100)
        _ = await TabRun(backend: backend, config: config).awaitTurn(tabID: UUID(), path: path, fromOffset: 0)
        XCTAssertEqual(backend.polls, 2)
    }

    /// The agent's process went away mid-turn: no idle will ever come, so the run ends at once.
    func testAShellAfterBusyEndsTheTurnAsAgentExited() async {
        let backend = ScriptedTabRunBackend(statuses: [.busy, .shell], resolveSlotAfterPolls: 100)
        let turn = await TabRun(backend: backend, config: config).awaitTurn(tabID: UUID(), path: path, fromOffset: 0)
        XCTAssertTrue(turn.agentExited)
        XCTAssertFalse(turn.timedOut)
        XCTAssertEqual(backend.polls, 2)
    }

    /// A `.shell` read before the turn was ever seen busy does not end it early: it holds for
    /// `busySeenTimeout` first, and a turn that does show up busy then runs to its idle.
    func testAShellBeforeBusyDoesNotEndTheTurnEarly() async {
        let backend = ScriptedTabRunBackend(statuses: [.shell, .busy, .busy, .idle], resolveSlotAfterPolls: 100)
        let turn = await TabRun(backend: backend, config: config).awaitTurn(tabID: UUID(), path: path, fromOffset: 0)
        XCTAssertFalse(turn.agentExited)
        XCTAssertEqual(backend.polls, 4)

        let dead = ScriptedTabRunBackend(statuses: [.shell], resolveSlotAfterPolls: 100)
        let started = Date()
        let gone = await TabRun(backend: dead, config: config).awaitTurn(tabID: UUID(), path: path, fromOffset: 0)
        XCTAssertTrue(gone.agentExited)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), config.busySeenTimeout)
    }

    func testAPromptIsRetypedUntilItLands() async {
        let backend = ScriptedTabRunBackend(statuses: [.idle], resolveSlotAfterPolls: 100)
        backend.landOnAttempt = 2
        backend.path = path
        let landed = await TabRun(backend: backend, config: config)
            .deliver("hello", tabID: UUID(), path: path, baselineUserCount: 0)
        XCTAssertTrue(landed)
        XCTAssertEqual(backend.typed, 2)
    }

    func testAPromptThatNeverLandsIsReported() async {
        let backend = ScriptedTabRunBackend(statuses: [.idle], resolveSlotAfterPolls: 100)
        backend.landOnAttempt = 99
        backend.path = path
        let landed = await TabRun(backend: backend, config: config)
            .deliver("hello", tabID: UUID(), path: path, baselineUserCount: 0)
        XCTAssertFalse(landed)
        XCTAssertEqual(backend.typed, 3)
    }

    /// A driver that takes input for certain (ACP: accepted = will be sent) is sent to once,
    /// even with the tab still `.unknown` past the wait and nothing in the transcript yet.
    func testAPromptAcceptedForCertainIsSentOnce() async {
        let backend = ScriptedTabRunBackend(statuses: [.unknown], resolveSlotAfterPolls: 100)
        backend.outcome = .accepted
        backend.path = path
        let landed = await TabRun(backend: backend, config: config)
            .deliver("hello", tabID: UUID(), path: path, baselineUserCount: 0)
        XCTAssertTrue(landed)
        XCTAssertEqual(backend.typed, 1)
    }
}

/// Statuses play out in order (the last one repeats); the slot resolves after a set number
/// of status reads; typing lands on a chosen attempt.
@MainActor
final class ScriptedTabRunBackend: TabRunBackend {
    private var statuses: [SessionStatus]
    private let resolveSlotAfterPolls: Int
    var slot: StructuredOutputState?
    var landOnAttempt = 1
    var path: String?
    private(set) var polls = 0
    private(set) var typed = 0
    /// Called on every status read with the poll number; may rewrite the slot.
    var onPoll: ((Int, inout StructuredOutputState?) -> Void)?

    init(statuses: [SessionStatus], resolveSlotAfterPolls: Int) {
        self.statuses = statuses
        self.resolveSlotAfterPolls = resolveSlotAfterPolls
    }

    /// What `inject` reports: `.typed` (a PTY — only the transcript can confirm it) by default.
    var outcome: InjectOutcome = .typed

    func inject(tabID: UUID, text: String) -> InjectOutcome {
        typed += 1
        guard outcome == .typed else { return outcome }
        guard typed == landOnAttempt, let path else { return .typed }
        FileManager.default.createFile(atPath: path, contents: Data(
            (#"{"type":"user","message":{"role":"user","content":"\#(text)"}}"# + "\n").utf8))
        return .typed
    }

    func liveStatus(tabID: UUID) -> SessionStatus {
        polls += 1
        onPoll?(polls, &slot)
        if polls >= resolveSlotAfterPolls { slot?.status = .fulfilled }
        return statuses.count > 1 ? statuses.removeFirst() : statuses[0]
    }

    func transcriptPath(tabID: UUID) -> String? { path }

    func structuredOutputState(tabID: UUID, type: ArmType) -> StructuredOutputState? { slot }
}
