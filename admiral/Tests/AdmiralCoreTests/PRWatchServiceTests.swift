import XCTest
@testable import AdmiralCore

@MainActor
final class PRWatchServiceTests: XCTestCase {
    private var host: FakeTerminalHost!
    private var manager: SessionManager!
    private var base: URL!
    private var store: PRWatchStore!
    private var idle: IdleClock!
    private var service: PRWatchService!
    private var session: AgentSession!
    private var watched = true
    /// Every repo the fetcher was asked about, in order — the cost control, made countable.
    private var fetched: [String] = []
    private var next: [PRStatus] = []
    private let root = "/tmp/repo"
    private let t0 = Date(timeIntervalSince1970: 3_100_000)

    override func setUp() async throws {
        try await super.setUp()
        host = FakeTerminalHost()
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("prwatch-svc-\(UUID().uuidString)")
        manager = SessionManager(host: host, claudeHome: base, executablePath: "/bin/echo",
                                 supportDir: base)
        store = PRWatchStore(base: base)
        idle = IdleClock()
        watched = true
        fetched = []
        next = [pr()]
        service = PRWatchService(
            manager: manager, store: store, idle: idle,
            isWatched: { [weak self] _ in self?.watched ?? false },
            fetch: { [weak self] _, root, _ in
                await MainActor.run {
                    self?.fetched.append(root)
                    return self?.next ?? []
                }
            })
        session = AgentSession(callsign: "worker", cwd: "/tmp", claudeSessionID: "sid-1",
                               status: .idle, token: "tok-1")
        session.touchedRepos = [TouchedRepo(root: root, branches: ["feature/ACME-1"],
                                            filesWritten: 3, insideSessionRoot: true)]
        manager.register(session, handle: host.spawn(executable: "/bin/echo", args: [], env: [:],
                                                     cwd: "/tmp", onExit: { _ in }))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: base)
        super.tearDown()
    }

    private func pr(merged: Bool = false, canMerge: Bool = false, approvals: Int = 0,
                    passed: Int = 0, running: Int = 1, failed: Int = 0) -> PRStatus {
        PRStatus(number: 920, title: "fix the thing", url: "https://gh/pull/920",
                 isMerged: merged, canMerge: canMerge, approvals: approvals,
                 checksPassed: passed, checksRunning: running, checksFailed: failed)
    }

    /// Put the session in `raw` the way the app learns it: claude writes its status to
    /// `sessions/<pid>.json`, and the tick reads it back.
    private func claudeReports(_ raw: String) throws {
        let dir = base.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{"pid":4242,"sessionId":"sid-1","status":"\#(raw)","updatedAt":100}"#
            .write(to: dir.appendingPathComponent("4242.json"), atomically: true, encoding: .utf8)
        manager.refreshStatuses()
    }

    private var injected: [String] { host.sent.filter { $0 != "\r" } }

    /// Fetch, land, deliver: the fetch is async, so a cycle is tick → drain → tick.
    private func cycle(at now: Date) async {
        service.tick(now: now)
        await service.drain()
        service.tick(now: now)
    }

    /// The gate, and the reason it exists: a session nobody is watching costs zero gh calls.
    func testDisarmedWatchdogNeverFetches() async {
        watched = false
        await cycle(at: t0)
        XCTAssertEqual(fetched, [])
        XCTAssertEqual(injected, [])
        XCTAssertNil(store.state(forSession: "sid-1"))
    }

    /// An ACP tab is polled only where its gh is there and logged in — asking the Mac's gh
    /// about a container path would be wrong, and a gh with no login would fail every minute.
    func testACPTabIsPolledOnlyWhenItsRecordEnablesPRWatch() async {
        service = PRWatchService(
            manager: manager, store: store, idle: idle,
            isWatched: { $0 == "sid-acp" },
            fetch: { [weak self] session, root, _ in
                await MainActor.run {
                    self?.fetched.append("\(session.callsign):\(root)")
                    return self?.next ?? []
                }
            })
        var acp = AgentSession(callsign: "agent", cwd: "/workspace", claudeSessionID: "sid-acp",
                               status: .idle, token: "tok-acp")
        acp.backend = .acp(agentName: "PPT")
        acp.touchedRepos = session.touchedRepos
        let caps = AcpCapabilities(initializeResult: .object([:]))
        acp.acpCapabilities = AcpCapabilityRecord(negotiated: caps, git: true, gh: true, ghAuthed: false)
        manager.register(acp, handle: host.spawn(executable: "/bin/echo", args: [], env: [:],
                                                 cwd: "/tmp", onExit: { _ in }))
        await cycle(at: t0)
        XCTAssertEqual(fetched, [], "gh not logged in in the agent's environment")

        manager.delete(acp.id)
        acp = AgentSession(id: UUID(), callsign: "agent", cwd: "/workspace", claudeSessionID: "sid-acp",
                           status: .idle, token: "tok-acp")
        acp.backend = .acp(agentName: "PPT")
        acp.touchedRepos = session.touchedRepos
        acp.acpCapabilities = AcpCapabilityRecord(negotiated: caps, git: true, gh: true, ghAuthed: true)
        manager.register(acp, handle: host.spawn(executable: "/bin/echo", args: [], env: [:],
                                                 cwd: "/tmp", onExit: { _ in }))
        await cycle(at: t0)
        XCTAssertEqual(fetched, ["agent:\(root)"], "the fetch is told which tab the repo is")
    }

    func testWatchedSessionFetchesAndTellsTheSessionOnce() async {
        await cycle(at: t0)
        XCTAssertEqual(fetched, [root])
        XCTAssertEqual(injected.count, 1)
        XCTAssertTrue(injected[0].contains("PR WATCH"), injected[0])
        XCTAssertTrue(injected[0].contains("repo #920"), injected[0])

        // Same status one minute later: polled again, nothing said.
        await cycle(at: t0.addingTimeInterval(61))
        XCTAssertEqual(fetched, [root, root])
        XCTAssertEqual(injected.count, 1)
    }

    /// A restarted Admiral rebuilds the service from scratch; only the file remembers.
    func testRestartWithUnchangedStatusSaysNothing() async {
        await cycle(at: t0)
        XCTAssertEqual(injected.count, 1)

        service = PRWatchService(
            manager: manager, store: PRWatchStore(base: base), idle: idle,
            isWatched: { _ in true },
            fetch: { [weak self] _, root, _ in
                await MainActor.run { self?.fetched.append(root); return self?.next ?? [] }
            })
        await cycle(at: t0.addingTimeInterval(600))
        XCTAssertEqual(fetched.count, 2, "it does poll again")
        XCTAssertEqual(injected.count, 1, "but it has nothing new to say")
    }

    func testThrottleHoldsTheSecondPollInsideTheInterval() async {
        await cycle(at: t0)
        await cycle(at: t0.addingTimeInterval(30))
        XCTAssertEqual(fetched, [root])
    }

    /// Nothing to learn from a merged PR, so the repo drops to the cooldown cadence.
    func testSettledRepoPollsOnTheCooldownCadence() async {
        next = [pr(merged: true, passed: 2, running: 0)]
        await cycle(at: t0)
        XCTAssertEqual(fetched, [root])
        XCTAssertEqual(injected, [], "never announced, so the merge is not news")

        await cycle(at: t0.addingTimeInterval(120))
        XCTAssertEqual(fetched, [root], "still inside the 10 minute cooldown")
        await cycle(at: t0.addingTimeInterval(601))
        XCTAssertEqual(fetched, [root, root])
    }

    /// A session mid-turn is told at once: claude takes a typed message while it works, and
    /// news that waits for a quiet moment never reaches a session that is always working.
    func testABusySessionIsToldAtOnce() async throws {
        try claudeReports("busy")
        idle.wake("sid-1")   // another nudge just spoke — no longer a reason to wait
        next = [pr(passed: 5, running: 0, failed: 1)]
        await cycle(at: t0)
        XCTAssertEqual(injected.count, 1)
        XCTAssertTrue(injected.first?.contains("checks FAILED") == true, "\(injected)")
    }

    /// An open dialog (claude's "waiting") is the one live state that holds the news: typed
    /// text would answer the dialog instead of reaching claude. It goes out once the dialog
    /// closes, busy or idle, without waiting for another poll.
    func testADialogHoldsTheNewsUntilItClosesThenItGoesOutOnce() async throws {
        try claudeReports("waiting")
        await cycle(at: t0)
        XCTAssertEqual(fetched, [root], "still polled, so pr_status stays current")
        XCTAssertEqual(injected, [], "held — typing would answer the dialog")

        try claudeReports("busy")
        for offset in [2.0, 3.0, 4.0, 5.0] { service.tick(now: t0.addingTimeInterval(offset)) }
        XCTAssertEqual(fetched, [root], "no new poll: the throttle is still holding")
        XCTAssertEqual(injected.count, 1, "delivered once, however many ticks it rode")
        XCTAssertTrue(injected.first?.contains("repo #920") == true, "\(injected)")
    }

    /// Mergeable arrives while the news is held, and the PR merges before the next poll. The
    /// mergeable news is the one worth having, and the merge that follows must not be filed
    /// as history just because nobody had said the PR yet.
    func testAPRHeldWhileMergeableIsToldAndItsLaterMergeIsNotSwallowed() async throws {
        try claudeReports("waiting")
        next = [pr(canMerge: true, approvals: 1, passed: 2, running: 0)]   // mergeable
        await cycle(at: t0)
        XCTAssertEqual(injected, [], "held")

        try claudeReports("idle")
        service.tick(now: t0.addingTimeInterval(2))
        XCTAssertEqual(injected.count, 1, "told as soon as it can be typed to")
        XCTAssertTrue(injected.first?.contains("mergeable") == true, "\(injected)")

        next = [pr(merged: true, approvals: 2, passed: 2, running: 0)]     // then merged
        await cycle(at: t0.addingTimeInterval(61))
        XCTAssertEqual(injected.count, 2)
        XCTAssertTrue(injected.last?.contains("merged") == true, "\(injected)")
    }

    /// The same race with nothing ever announced: held while blocked, merged before the next
    /// chance to speak. Without the `seenBefore` guard the merge is swallowed as history.
    func testAMergeThatLandsWhileTheFirstNewsIsHeldIsStillAnnounced() async throws {
        try claudeReports("waiting")
        await cycle(at: t0)                                               // blocked, held
        XCTAssertEqual(injected, [])

        next = [pr(merged: true, approvals: 2, passed: 2, running: 0)]
        await cycle(at: t0.addingTimeInterval(61))
        XCTAssertEqual(injected, [], "still held")

        try claudeReports("busy")
        service.tick(now: t0.addingTimeInterval(63))
        XCTAssertEqual(injected.count, 1, "the merge is news, not history")
        XCTAssertTrue(injected.first?.contains("merged") == true, "\(injected)")
    }

    /// The retry reads the last poll back from disk, so the gate has to hold on ticks that
    /// fetch nothing too — otherwise disarming the watchdog would leave a session still being
    /// injected from state it can no longer refresh.
    func testDisarmingAfterAHoldStopsTheRetry() async throws {
        try claudeReports("waiting")
        await cycle(at: t0)
        XCTAssertEqual(injected, [], "held, and now on disk")

        watched = false
        try claudeReports("idle")
        service.tick(now: t0.addingTimeInterval(2))
        XCTAssertEqual(injected, [], "nobody is watching any more")
    }

    /// A driven session ends its turn with a CI watcher running in the background, and claude
    /// reports that as `"shell"`. It is alive, and it has to be told when its checks fail.
    func testASessionIdleWithABackgroundTaskRunningIsTold() async throws {
        try claudeReports("shell")
        next = [pr(passed: 5, running: 0, failed: 1)]
        await cycle(at: t0)
        XCTAssertEqual(fetched, [root])
        XCTAssertEqual(injected.count, 1)
        XCTAssertTrue(injected.first?.contains("checks FAILED") == true, "\(injected)")
    }

    /// Admiral's own `.shell` — the claude process exited — still keeps the tab out: there is
    /// nobody left to tell, and typing the news into the bare shell would run it.
    func testAnExitedSessionIsNeverPolledOrTold() async {
        var exited = AgentSession(callsign: "gone", cwd: "/tmp", claudeSessionID: "sid-3",
                                  status: .shell, token: "tok-3")
        exited.touchedRepos = [TouchedRepo(root: "/tmp/gone", branches: ["feature/ACME-3"],
                                           filesWritten: 1, insideSessionRoot: true)]
        manager.register(exited, handle: host.spawn(executable: "/bin/echo", args: [], env: [:],
                                                    cwd: "/tmp", onExit: { _ in }))
        await cycle(at: t0)
        XCTAssertFalse(fetched.contains("/tmp/gone"))
        XCTAssertNil(store.state(forSession: "sid-3"))
    }

    /// A tab launched accepting peer messages gets PR WATCH on its messaging socket, so the
    /// news never lands in its input box on top of a half-typed prompt.
    func testATabThatAcceptsGetsPRNewsOverTheSocket() async throws {
        var socketed: [String] = []
        manager.sendPeerMessage = { body, _, _ in socketed.append(body) }
        let sock = base.appendingPathComponent("88.sock")
        try FileManager.default.createDirectory(at: base.appendingPathComponent("sessions"),
                                                withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: sock.path, contents: Data())
        try #"{"pid":88,"sessionId":"sid-2","status":"busy","messagingSocketPath":"\#(sock.path)"}"#
            .write(to: base.appendingPathComponent("sessions/88.json"), atomically: true, encoding: .utf8)
        var tab = AgentSession(callsign: "socketed", cwd: "/tmp", claudeSessionID: "sid-2",
                               status: .busy, token: "tok-2")
        tab.acceptsPeerMessages = true
        tab.touchedRepos = [TouchedRepo(root: "/tmp/other", branches: ["feature/ACME-2"],
                                        filesWritten: 1, insideSessionRoot: true)]
        manager.register(tab, handle: host.spawn(executable: "/bin/echo", args: [], env: [:],
                                                 cwd: "/tmp", onExit: { _ in }))
        watched = true

        await cycle(at: t0)
        XCTAssertEqual(socketed.count, 1)
        XCTAssertTrue(socketed.first?.contains("PR WATCH") == true, "\(socketed)")
        XCTAssertFalse(injected.contains { $0.contains("/tmp/other") || $0.contains("other #") },
                       "the socketed tab's news was not typed")
    }

    /// The watcher is also the panel's PR source for sessions that are not on screen.
    func testFetchedStatusReachesTheFootprintPanel() async {
        await cycle(at: t0)
        XCTAssertEqual(manager.sessions.first?.touchedRepos.first?.prs.first?.number, 920)
    }

    func testRepoWithoutABranchIsNeverFetched() async {
        var bare = AgentSession(callsign: "bare", cwd: "/tmp", claudeSessionID: "sid-2",
                                status: .idle, token: "tok-2")
        bare.touchedRepos = [TouchedRepo(root: "/tmp/nobranch", branches: [],
                                         filesWritten: 1, insideSessionRoot: true)]
        manager.register(bare, handle: host.spawn(executable: "/bin/echo", args: [], env: [:],
                                                  cwd: "/tmp", onExit: { _ in }))
        await cycle(at: t0)
        XCTAssertFalse(fetched.contains("/tmp/nobranch"))
    }
}
