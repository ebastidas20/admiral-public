import XCTest
@testable import AdmiralCore

/// A due schedule opens a NEW tab named after the schedule and types its prompt; every run —
/// including one that never got a session — leaves a line in the schedule's index.
@MainActor
final class SchedulerServiceTests: XCTestCase {
    private var base: URL!
    private var store: ScheduleStore!
    private var backend: FakeScheduleBackend!
    private var clock: Date!
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()
    static let schema = #"{"type":"object","properties":{"summary":{"type":"string"}},"required":["summary"],"additionalProperties":false}"#

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("scheduler-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        store = ScheduleStore(base: base)
        backend = FakeScheduleBackend(dir: base)
        clock = date(2026, 10, 2, 9, 0, 10)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: base) }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }

    private func service() -> SchedulerService {
        SchedulerService(store: store, backend: backend, calendar: calendar, now: { [unowned self] in self.clock },
                         runConfig: TabRun.Config(busySeenTimeout: 0.05, turnTimeout: 0.3, pollInterval: 0.002,
                                                  injectReadyTimeout: 0.05, injectVerifyTimeout: 0.05,
                                                  injectMaxAttempts: 2),
                         providers: { [CCSwitchProvider(id: "p-kimi", name: "Kimi via Fireworks", env: [:])] })
    }

    @discardableResult
    private func saved(_ name: String = "nightly", cron: String = "0 9 * * *", lastFire: Date? = nil,
                       schema: String? = nil, scratch: Bool = true, enabled: Bool = true) -> Schedule {
        let s = Schedule(name: name, cron: cron, cwd: base.path, prompt: "write the report", scratch: scratch,
                         outputSchema: schema, enabled: enabled, lastFire: lastFire ?? date(2026, 10, 2, 8, 59))
        store.save(s)
        return s
    }

    private func settle(_ scheduler: SchedulerService) async {
        for task in scheduler.tasks.values { await task.value }
    }

    // MARK: - Running

    func testADueScheduleOpensATabNamedAfterItAndTypesItsPrompt() async throws {
        let s = saved()
        let scheduler = service()
        scheduler.tick()
        await settle(scheduler)
        XCTAssertEqual(backend.opened.map(\.name), ["nightly"])
        XCTAssertEqual(backend.opened.first?.cwd, base.path)
        XCTAssertEqual(backend.opened.first?.scratch, true)
        XCTAssertEqual(backend.typed, ["write the report"])
        let run = try XCTUnwrap(store.runs(for: s.id).first)
        XCTAssertEqual(run.status, .succeeded)
        XCTAssertEqual(run.trigger, .cron)
        XCTAssertEqual(run.scheduledFor, date(2026, 10, 2, 9, 0))
        XCTAssertEqual(run.callsign, "nightly")
        XCTAssertEqual(run.sessionID, backend.opened.first?.sessionID)
    }

    func testNothingRunsBeforeItsTime() async {
        let s = saved()
        clock = date(2026, 10, 2, 8, 59, 59)
        let scheduler = service()
        scheduler.tick()
        await settle(scheduler)
        XCTAssertEqual(backend.opened.count, 0)
        XCTAssertEqual(store.runs(for: s.id), [])
    }

    func testAFireRunsOnce() async {
        saved()
        let scheduler = service()
        scheduler.tick()
        await settle(scheduler)
        scheduler.tick()
        await settle(scheduler)
        XCTAssertEqual(backend.opened.count, 1)
    }

    func testARegularTabWhenScratchIsOff() async {
        saved(scratch: false)
        let scheduler = service()
        scheduler.tick()
        await settle(scheduler)
        XCTAssertEqual(backend.opened.first?.scratch, false)
    }

    func testADisabledScheduleDoesNotRun() async {
        saved(enabled: false)
        let scheduler = service()
        scheduler.tick()
        await settle(scheduler)
        XCTAssertEqual(backend.opened.count, 0)
    }

    func testARunStillGoingMakesTheNextOneSkip() async throws {
        let s = saved()
        backend.stayBusy = true
        let scheduler = service()
        let first = try scheduler.runNow(name: "nightly").get()
        let second = try scheduler.runNow(name: "nightly").get()
        XCTAssertEqual(first.status, .running)
        XCTAssertEqual(second.status, .skipped)
        XCTAssertEqual(backend.opened.count, 1)
        await settle(scheduler)
        let skipped = try XCTUnwrap(store.runs(for: s.id).first { $0.id == second.id })
        XCTAssertEqual(skipped.status, .skipped)
        XCTAssertEqual(skipped.trigger, .now)
        XCTAssertNil(skipped.sessionID)
        XCTAssertNotNil(skipped.note)
    }

    /// Admiral was closed from 9:00 to 12:30: the 12:00 fire runs once, late, and the two
    /// before it are recorded as missed — not replayed.
    func testMissedFiresRunOnceLateAndAreRecorded() async throws {
        let s = saved(cron: "0 * * * *", lastFire: date(2026, 10, 2, 9))
        clock = date(2026, 10, 2, 12, 30)
        let scheduler = service()
        scheduler.tick()
        await settle(scheduler)
        XCTAssertEqual(backend.opened.count, 1)
        let runs = store.runs(for: s.id)
        let late = try XCTUnwrap(runs.first { $0.trigger == .late })
        XCTAssertEqual(late.scheduledFor, date(2026, 10, 2, 12))
        XCTAssertEqual(late.status, .succeeded)
        let missed = try XCTUnwrap(runs.first { $0.status == .missed })
        XCTAssertEqual(missed.scheduledFor, date(2026, 10, 2, 10))
        XCTAssertNil(missed.sessionID)
        XCTAssertTrue(missed.note?.contains("2 earlier runs") == true, missed.note ?? "")
    }

    func testAFireMoreThanAMinuteBehindRunsLate() async throws {
        let s = saved()
        clock = date(2026, 10, 2, 9, 2)
        let scheduler = service()
        scheduler.tick()
        await settle(scheduler)
        let runs = store.runs(for: s.id)
        XCTAssertEqual(runs.map(\.trigger), [.late])
    }

    func testAPromptThatNeverReachesClaudeFailsTheRun() async throws {
        let s = saved()
        backend.dropTyping = true
        let scheduler = service()
        scheduler.tick()
        await settle(scheduler)
        let run = try XCTUnwrap(store.runs(for: s.id).first)
        XCTAssertEqual(run.status, .failed)
        XCTAssertTrue(run.note?.contains("never reached claude") == true, run.note ?? "")
        XCTAssertNotNil(run.sessionID, "the tab did start: the index still points at it")
    }

    func testARunPastItsTimeoutIsTimedOut() async throws {
        let s = saved()
        backend.stayBusy = true
        let scheduler = service()
        scheduler.tick()
        await settle(scheduler)
        XCTAssertEqual(store.runs(for: s.id).first?.status, .timedOut)
        XCTAssertEqual(backend.closed, [], "a timed-out run's tab stays open")
    }

    func testATabThatCannotOpenIsAFailedRun() async throws {
        let s = saved()
        backend.launchError = "unknown provider 'kimi'"
        let scheduler = service()
        let run = try scheduler.runNow(name: "nightly").get()
        XCTAssertEqual(run.status, .failed)
        XCTAssertEqual(store.runs(for: s.id).first?.note, "unknown provider 'kimi'")
        XCTAssertNil(store.runs(for: s.id).first?.sessionID)
        backend.launchError = nil
        XCTAssertEqual(try scheduler.runNow(name: "nightly").get().status, .running, "a failed launch holds nothing")
        await settle(scheduler)
    }

    func testASchemaRunEndsWithItsStructuredOutput() async throws {
        let s = saved(schema: Self.schema)
        backend.outputStatus = .fulfilled
        let scheduler = service()
        scheduler.tick()
        await settle(scheduler)
        XCTAssertNotNil(backend.opened.first?.schema, "the schema is set on the tab before the prompt")
        XCTAssertEqual(store.runs(for: s.id).first?.status, .succeeded)
    }

    func testASchemaRunWithoutItsOutputFails() async throws {
        let s = saved(schema: Self.schema)
        backend.outputStatus = .failed
        let scheduler = service()
        scheduler.tick()
        await settle(scheduler)
        let run = try XCTUnwrap(store.runs(for: s.id).first)
        XCTAssertEqual(run.status, .failed)
        XCTAssertTrue(run.note?.contains("structured output") == true, run.note ?? "")
    }

    /// The Stop hook can re-arm the output slot while a run continues past its first answer. A
    /// run is judged by the slot's final state: the transient armed rounds neither end it early
    /// nor taint it once the last round is fulfilled…
    func testASchemaRunThatWasReArmedMidwaySucceedsOnItsFinalRound() async throws {
        let s = saved(schema: Self.schema)
        backend.outputScript = [.fulfilled, .armed, .armed, .fulfilled]
        let scheduler = service()
        scheduler.tick()
        await settle(scheduler)
        XCTAssertEqual(store.runs(for: s.id).first?.status, .succeeded)
    }

    /// …and a final round that gave up fails it, whatever the earlier one delivered.
    func testASchemaRunWhoseFinalRoundFailedFails() async throws {
        let s = saved(schema: Self.schema)
        backend.outputScript = [.fulfilled, .armed, .armed, .failed]
        let scheduler = service()
        scheduler.tick()
        await settle(scheduler)
        let run = try XCTUnwrap(store.runs(for: s.id).first)
        XCTAssertEqual(run.status, .failed)
        XCTAssertTrue(run.note?.contains("structured output") == true, run.note ?? "")
    }

    /// Only a finished scratch tab this schedule opened is closed; a regular tab, or a
    /// scratch tab that merely shares the name, is left alone.
    func testAFinishedScratchTabOfAnEarlierRunIsClosedFirst() async throws {
        saved()
        let scheduler = service()
        _ = try scheduler.runNow(name: "nightly").get()
        await settle(scheduler)
        let earlier = try XCTUnwrap(backend.openTabs.first)
        let regular = backend.addTab(name: "nightly", scratch: false)
        let stranger = backend.addTab(name: "nightly", scratch: true)
        _ = try scheduler.runNow(name: "nightly").get()
        await settle(scheduler)
        XCTAssertEqual(backend.closed, [earlier.id])
        XCTAssertTrue(backend.openTabs.contains { $0.id == regular.id })
        XCTAssertTrue(backend.openTabs.contains { $0.id == stranger.id })
    }

    func testARunLeftRunningByAQuitAdmiralEndsFailed() async throws {
        let s = saved()
        store.record(ScheduleRun(id: "r1", trigger: .cron, status: .running, startedAt: date(2026, 10, 2, 8)), for: s.id)
        let scheduler = service()
        XCTAssertEqual(store.runs(for: s.id).first?.status, .running, "creating a scheduler ends nothing by itself")
        scheduler.endInterruptedRuns()
        let run = try XCTUnwrap(store.runs(for: s.id).first)
        XCTAssertEqual(run.status, .failed)
        XCTAssertTrue(run.note?.contains("Admiral closed") == true, run.note ?? "")
    }

    func testRunNowNamesAnUnknownSchedule() {
        XCTAssertThrowsError(try service().runNow(name: "nope").get())
    }

    // MARK: - Attention (the sidebar's red dot)

    private func needsAttention(_ scheduler: SchedulerService) -> Bool? {
        scheduler.overview().first?.needsAttention
    }

    func testASucceededRunNeedsNoAttention() async {
        saved()
        let scheduler = service()
        scheduler.tick()
        await settle(scheduler)
        XCTAssertEqual(needsAttention(scheduler), false)
    }

    func testAFailedRunNeedsAttention() async {
        saved()
        backend.dropTyping = true
        let scheduler = service()
        scheduler.tick()
        await settle(scheduler)
        XCTAssertEqual(needsAttention(scheduler), true)
    }

    func testATimedOutRunNeedsAttention() async {
        saved()
        backend.stayBusy = true
        let scheduler = service()
        scheduler.tick()
        await settle(scheduler)
        XCTAssertEqual(needsAttention(scheduler), true)
    }

    /// The missed line is never the newest on its own (the late run is recorded right after
    /// it), so a late run that succeeds still carries the fires it missed.
    func testMissedFiresNeedAttentionThoughTheLateRunSucceeded() async {
        let s = saved(cron: "0 * * * *", lastFire: date(2026, 10, 2, 9))
        clock = date(2026, 10, 2, 12, 30)
        let scheduler = service()
        scheduler.tick()
        await settle(scheduler)
        XCTAssertEqual(store.runs(for: s.id).first?.status, .succeeded)
        XCTAssertEqual(needsAttention(scheduler), true)
    }

    func testARunningAndASkippedRunNeedNoAttention() async throws {
        saved()
        backend.stayBusy = true
        let scheduler = service()
        _ = try scheduler.runNow(name: "nightly").get()
        XCTAssertEqual(try scheduler.runNow(name: "nightly").get().status, .skipped)
        XCTAssertEqual(needsAttention(scheduler), false)
        await settle(scheduler)
    }

    func testANewerGoodRunClearsAnOlderFailure() async {
        let s = saved(cron: "0 * * * *")
        backend.dropTyping = true
        let scheduler = service()
        scheduler.tick()
        await settle(scheduler)
        XCTAssertEqual(needsAttention(scheduler), true)
        backend.dropTyping = false
        clock = date(2026, 10, 2, 10, 0, 10)
        scheduler.tick()
        await settle(scheduler)
        XCTAssertEqual(store.runs(for: s.id).first?.status, .succeeded)
        XCTAssertEqual(needsAttention(scheduler), false)
    }

    func testAPausedScheduleNeedsNoAttention() async {
        var s = saved()
        backend.dropTyping = true
        let scheduler = service()
        scheduler.tick()
        await settle(scheduler)
        XCTAssertEqual(needsAttention(scheduler), true)
        s.enabled = false
        store.save(s)
        XCTAssertEqual(needsAttention(scheduler), false)
    }

    func testAnEmptySchemaFieldMeansNoSchema() throws {
        XCTAssertNil(SchedulerService.outputSchemaProblem(""))
        XCTAssertNil(SchedulerService.outputSchemaProblem("  \n "))
        XCTAssertNil(SchedulerService.outputSchemaProblem(Self.schema))
        XCTAssertNotNil(SchedulerService.outputSchemaProblem("{not json"))
        let scheduler = service()
        let withSchema = try scheduler.set(spec("reports", schema: Self.schema)).get()
        XCTAssertEqual(withSchema.outputSchema, Self.schema)
        let cleared = try scheduler.set(ScheduleSpec(name: "reports", outputSchema: "   ")).get()
        XCTAssertNil(cleared.outputSchema, "an emptied field drops the schema")
    }

    func testPausingThenResumingStartsFromNowWithoutCatchingUp() throws {
        let scheduler = service()
        _ = try scheduler.set(spec("hourly", cron: "0 * * * *")).get()
        XCTAssertFalse(try scheduler.set(ScheduleSpec(name: "hourly", enabled: false)).get().enabled)
        clock = date(2026, 10, 2, 14, 30)
        let resumed = try scheduler.set(ScheduleSpec(name: "hourly", enabled: true)).get()
        XCTAssertTrue(resumed.enabled)
        XCTAssertEqual(resumed.lastFire, clock, "the hours spent paused are not owed")
    }

    func testTheSidebarLineNamesASingleEnabledSchedule() throws {
        let scheduler = service()
        _ = try scheduler.set(spec("nightly", cron: "0 9 * * *")).get()
        _ = try scheduler.set(ScheduleSpec(name: "weekly", cron: "0 9 * * 1", cwd: base.path, prompt: "go", enabled: false)).get()
        let line = try XCTUnwrap(SchedulerService.sidebarLine(scheduler.overview(), now: clock))
        XCTAssertEqual(line, .init(lead: "nightly",
                                   countdown: SchedulerService.countdown(to: date(2026, 10, 3, 9), from: clock)))
    }

    func testTheSidebarLineCountsSeveralAndGivesTheSoonest() throws {
        let scheduler = service()
        _ = try scheduler.set(spec("nightly", cron: "0 9 * * *")).get()
        _ = try scheduler.set(spec("hourly", cron: "0 * * * *")).get()
        _ = try scheduler.set(ScheduleSpec(name: "weekly", cron: "0 9 * * 1", cwd: base.path, prompt: "go", enabled: false)).get()
        let line = try XCTUnwrap(SchedulerService.sidebarLine(scheduler.overview(), now: clock))
        XCTAssertEqual(line, .init(lead: "2 active",
                                   countdown: "next in " + SchedulerService.countdown(to: date(2026, 10, 2, 10), from: clock)))
    }

    func testNoSidebarLineWhenNothingIsEnabled() throws {
        let scheduler = service()
        XCTAssertNil(SchedulerService.sidebarLine(scheduler.overview(), now: clock))
        _ = try scheduler.set(ScheduleSpec(name: "weekly", cron: "0 9 * * 1", cwd: base.path, prompt: "go", enabled: false)).get()
        XCTAssertNil(SchedulerService.sidebarLine(scheduler.overview(), now: clock))
    }

    func testCountdown() {
        let now = date(2026, 10, 2, 9)
        func countdown(_ seconds: TimeInterval) -> String {
            SchedulerService.countdown(to: now.addingTimeInterval(seconds), from: now)
        }
        XCTAssertEqual(countdown(-5), "<1m")
        XCTAssertEqual(countdown(59), "<1m")
        XCTAssertEqual(countdown(14 * 60 + 59), "14m")
        XCTAssertEqual(countdown(2 * 3600 + 14 * 60), "2h 14m")
        XCTAssertEqual(countdown(3 * 3600), "3h")
        XCTAssertEqual(countdown(86400 + 4 * 3600 + 30 * 60), "1d 4h")
        XCTAssertEqual(countdown(2 * 86400), "2d")
    }

    // MARK: - Setting

    private func spec(_ name: String, cron: String? = "0 9 * * *", cwd: String? = nil, prompt: String? = "go",
                      schema: String? = nil) -> ScheduleSpec {
        ScheduleSpec(name: name, cron: cron, cwd: cwd ?? base.path, prompt: prompt, outputSchema: schema)
    }

    func testANewScheduleFollowsTheTabNameRuleAndStartsFromNow() throws {
        let s = try service().set(spec("night report")).get()
        XCTAssertEqual(s.name, "night-report")
        XCTAssertEqual(s.lastFire, clock, "no catching up on fires from before it existed")
        XCTAssertTrue(s.scratch, "scratch by default")
        XCTAssertEqual(store.all().map(\.name), ["night-report"])
    }

    func testANameThatSanitizesToNothingIsRefused() {
        XCTAssertThrowsError(try service().set(spec("\"<>\"")).get()) { error in
            XCTAssertTrue(String(describing: error).contains("name"), "\(error)")
        }
    }

    func testTwoSchedulesCannotShareAName() throws {
        let scheduler = service()
        _ = try scheduler.set(spec("report")).get()
        XCTAssertThrowsError(try scheduler.set(spec("other", prompt: "x")).flatMap { _ in
            scheduler.set(ScheduleSpec(name: "other", newName: "REPORT"))
        }.get())
    }

    func testEveryProblemIsListed() {
        let bad = ScheduleSpec(name: "x", cron: "0 25 * * *", cwd: "/no/such/folder", prompt: " ",
                               outputSchema: #"{"type":"object"}"#)
        XCTAssertThrowsError(try service().set(bad).get()) { error in
            let problems = (error as? ScheduleProblems)?.problems ?? []
            XCTAssertEqual(problems.count, 4, "\(problems)")
            XCTAssertTrue(problems.contains { $0.contains("hour") })
            XCTAssertTrue(problems.contains { $0.contains("/no/such/folder") })
            XCTAssertTrue(problems.contains { $0.contains("prompt") })
            XCTAssertTrue(problems.contains { $0.contains("schema") })
        }
    }

    func testACronThatNeverFiresIsRefused() {
        XCTAssertThrowsError(try service().set(spec("x", cron: "0 0 30 2 *")).get()) { error in
            XCTAssertTrue(String(describing: error).contains("never"), "\(error)")
        }
    }

    func testAnUpdateKeepsWhatItDoesNotMention() throws {
        let scheduler = service()
        let created = try scheduler.set(spec("report", schema: Self.schema)).get()
        let updated = try scheduler.set(ScheduleSpec(name: "report", prompt: "new prompt")).get()
        XCTAssertEqual(updated.id, created.id)
        XCTAssertEqual(updated.prompt, "new prompt")
        XCTAssertEqual(updated.cron, created.cron)
        XCTAssertEqual(updated.cwd, created.cwd)
        XCTAssertEqual(updated.outputSchema, created.outputSchema)
    }

    func testARenameKeepsTheHistory() throws {
        let scheduler = service()
        let created = try scheduler.set(spec("report")).get()
        store.record(ScheduleRun(id: "r1", trigger: .now, status: .succeeded, startedAt: clock), for: created.id)
        let renamed = try scheduler.set(ScheduleSpec(name: "report", newName: "daily report")).get()
        XCTAssertEqual(renamed.id, created.id)
        XCTAssertEqual(renamed.name, "daily-report")
        XCTAssertEqual(store.runs(for: renamed.id).map(\.id), ["r1"])
    }

    func testChangingTheCronDoesNotCatchUp() throws {
        let old = saved(lastFire: date(2026, 9, 1))
        let updated = try service().set(ScheduleSpec(name: old.name, cron: "*/5 * * * *")).get()
        XCTAssertEqual(updated.lastFire, clock)
    }

    // MARK: - Model and effort

    /// Every run launches on the claude model the schedule names — opus, the CLI alias, when
    /// it names none — and carries the effort it names, or none.
    func testRunsLaunchOnTheModelTheScheduleNames() async throws {
        let scheduler = service()
        var naming = spec("report")
        naming.model = "haiku"
        naming.effort = "low"
        _ = try scheduler.set(naming).get()
        _ = try scheduler.runNow(name: "report").get()
        await settle(scheduler)
        XCTAssertEqual(backend.opened.first?.model, "haiku")
        XCTAssertEqual(backend.opened.first?.effort, "low")
    }

    func testAScheduleThatNamesNoModelLaunchesOnOpusWithNoEffort() async throws {
        saved()
        let scheduler = service()
        _ = try scheduler.runNow(name: "nightly").get()
        await settle(scheduler)
        XCTAssertEqual(backend.opened.first?.model, "opus", "opus is the default model")
        XCTAssertNil(backend.opened.first?.effort, "no effort named means claude's own default")
    }

    /// schedules/<id>.json can be edited after `set` checked it. A model or effort outside its
    /// closed set fails the run before any tab opens, so it never reaches claude's command line.
    func testAModelOrEffortEditedIntoTheFileFailsTheRunWithoutOpeningATab() throws {
        for (model, effort) in [("opus --verbose", nil), ("haiku", "high; echo hi")] as [(String, String?)] {
            let s = Schedule(name: "edited", cron: "0 9 * * *", cwd: base.path, prompt: "go",
                             model: model, effort: effort, lastFire: date(2026, 10, 2, 8, 59))
            store.save(s)
            let run = try service().runNow(name: "edited").get()
            XCTAssertEqual(run.status, .failed, model)
            XCTAssertEqual(backend.opened.count, 0, "no tab opens for \(model) / \(effort ?? "-")")
            store.delete(s.id)
        }
    }

    func testAModelAndEffortAreNormalizedToTheCLISpelling() throws {
        var naming = spec("report")
        naming.model = "Fable"
        naming.effort = "High"
        let s = try service().set(naming).get()
        XCTAssertEqual(s.model, "fable")
        XCTAssertEqual(s.effort, "high")
    }

    func testAnUnknownModelOrEffortIsRefusedNamingTheValidOnes() {
        var bad = spec("report")
        bad.model = "gpt-5"
        bad.effort = "ultra"
        XCTAssertThrowsError(try service().set(bad).get()) { error in
            let problems = (error as? ScheduleProblems)?.problems ?? []
            XCTAssertTrue(problems.contains { $0.contains("sonnet, haiku, opus or fable") }, "\(problems)")
            XCTAssertTrue(problems.contains { $0.contains("low, medium, high, xhigh or max") }, "\(problems)")
        }
    }

    func testAnEmptyModelOrEffortGoesBackToTheDefault() throws {
        let scheduler = service()
        var withBoth = spec("report")
        withBoth.model = "haiku"
        withBoth.effort = "low"
        _ = try scheduler.set(withBoth).get()
        let cleared = try scheduler.set(ScheduleSpec(name: "report", model: "  ", effort: "  ")).get()
        XCTAssertNil(cleared.model, "an emptied model means the default (opus) again")
        XCTAssertNil(cleared.effort)
    }

    func testAnUpdateKeepsTheModelAndEffortItDoesNotMention() throws {
        let scheduler = service()
        var withBoth = spec("report")
        withBoth.model = "fable"
        withBoth.effort = "xhigh"
        _ = try scheduler.set(withBoth).get()
        let updated = try scheduler.set(ScheduleSpec(name: "report", prompt: "new prompt")).get()
        XCTAssertEqual(updated.model, "fable")
        XCTAssertEqual(updated.effort, "xhigh")
    }

    /// A schedule saved before model and effort existed still loads — missing keys are nil,
    /// not a decode failure — and runs on the default model.
    func testAScheduleFileFromBeforeModelAndEffortStillLoadsAndRuns() async throws {
        let s = saved()
        let file = base.appendingPathComponent("schedules/\(s.id.uuidString).json")
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        obj.removeValue(forKey: "model")
        obj.removeValue(forKey: "effort")
        try JSONSerialization.data(withJSONObject: obj).write(to: file)
        let loaded = try XCTUnwrap(store.all().first)
        XCTAssertEqual(loaded.name, "nightly")
        XCTAssertNil(loaded.model)
        XCTAssertNil(loaded.effort)
        let scheduler = service()
        _ = try scheduler.runNow(name: "nightly").get()
        await settle(scheduler)
        XCTAssertEqual(backend.opened.first?.model, "opus")
    }

    /// A schedule can run on a custom model: its CC Switch provider is checked when it is set
    /// and handed to every run's tab.
    func testAScheduleRunsOnItsCustomModel() async throws {
        let scheduler = service()
        var withProvider = spec("report")
        withProvider.provider = "kimi via fireworks"
        let s = try scheduler.set(withProvider).get()
        XCTAssertEqual(s.provider, "kimi via fireworks")
        _ = try scheduler.runNow(name: "report").get()
        await settle(scheduler)
        XCTAssertEqual(backend.opened.first?.provider, "kimi via fireworks")
    }

    func testAnUnknownProviderIsRefusedNamingTheKnownOnes() {
        var bad = spec("report")
        bad.provider = "nope"
        XCTAssertThrowsError(try service().set(bad).get()) { error in
            XCTAssertTrue(String(describing: error).contains("unknown provider 'nope'"), "\(error)")
            XCTAssertTrue(String(describing: error).contains("Kimi via Fireworks"), "\(error)")
        }
    }

    func testAnEmptyProviderGoesBackToStock() throws {
        let scheduler = service()
        var withProvider = spec("report")
        withProvider.provider = "p-kimi"
        _ = try scheduler.set(withProvider).get()
        let stock = try scheduler.set(ScheduleSpec(name: "report", provider: "")).get()
        XCTAssertNil(stock.provider)
    }

    func testDeleteRemovesTheSchedule() {
        saved()
        let scheduler = service()
        XCTAssertTrue(scheduler.delete(name: "nightly"))
        XCTAssertFalse(scheduler.delete(name: "nightly"))
        XCTAssertEqual(store.all(), [])
    }
}

/// Opens tabs on paper: typing appends the prompt to the tab's transcript (as claude does on
/// submit), and a typed tab reads busy once, then idle.
@MainActor
final class FakeScheduleBackend: ScheduleBackend {
    struct Opened { let name: String; let cwd: String; let scratch: Bool; let provider: String?; let model: String?; let effort: String?; let schema: JSONValue?; let sessionID: String }

    let dir: URL
    private(set) var opened: [Opened] = []
    private(set) var typed: [String] = []
    private(set) var closed: [UUID] = []
    private(set) var openTabs: [ScheduleTab] = []
    var launchError: String?
    var dropTyping = false
    var stayBusy = false
    var outputStatus: StructuredOutputState.Status?
    /// Successive reads of the output slot's status (the last one repeats); wins over `outputStatus`.
    var outputScript: [StructuredOutputState.Status] = []
    private var paths: [UUID: String] = [:]
    private var busyPolls: [UUID: Int] = [:]

    init(dir: URL) { self.dir = dir }

    @discardableResult
    func addTab(name: String, scratch: Bool) -> ScheduleTab {
        let tab = ScheduleTab(id: UUID(), name: name, sessionID: UUID().uuidString.lowercased(), scratch: scratch, busy: false)
        openTabs.append(tab)
        return tab
    }

    func openRunTab(name: String, cwd: String, scratch: Bool, provider: String?, model: String?,
                    effort: String?, outputSchema: JSONValue?) -> Result<ScheduleTab, ScheduleLaunchError> {
        if let launchError { return .failure(ScheduleLaunchError(message: launchError)) }
        let tab = addTab(name: name, scratch: scratch)
        let sid = tab.sessionID!
        opened.append(Opened(name: name, cwd: cwd, scratch: scratch, provider: provider, model: model,
                            effort: effort, schema: outputSchema, sessionID: sid))
        paths[tab.id] = transcriptPath(sessionID: sid, cwd: cwd)
        return .success(tab)
    }

    func tabs(named name: String) -> [ScheduleTab] { openTabs.filter { $0.name == name } }

    func closeTab(_ id: UUID) {
        closed.append(id)
        openTabs.removeAll { $0.id == id }
    }

    func transcriptPath(sessionID: String, cwd: String) -> String {
        dir.appendingPathComponent("\(sessionID).jsonl").path
    }

    func inject(tabID: UUID, text: String) -> InjectOutcome {
        typed.append(text)
        guard !dropTyping, let path = paths[tabID] else { return .typed }
        let line = #"{"type":"user","message":{"role":"user","content":"\#(text)"}}"# + "\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
        }
        busyPolls[tabID] = 1
        return .typed
    }

    func liveStatus(tabID: UUID) -> SessionStatus {
        guard let polls = busyPolls[tabID] else { return .idle }
        if stayBusy { return .busy }
        if polls > 0 {
            busyPolls[tabID] = polls - 1
            return .busy
        }
        return .idle
    }

    func transcriptPath(tabID: UUID) -> String? { paths[tabID] }

    func structuredOutputState(tabID: UUID, type: ArmType) -> StructuredOutputState? {
        guard type == .output else { return nil }
        if !outputScript.isEmpty {
            let next = outputScript.count > 1 ? outputScript.removeFirst() : outputScript[0]
            return StructuredOutputState(schema: .object([:]), delivery: .jsonText, status: next)
        }
        guard let outputStatus else { return nil }
        return StructuredOutputState(schema: .object([:]), delivery: .jsonText, status: outputStatus)
    }
}
