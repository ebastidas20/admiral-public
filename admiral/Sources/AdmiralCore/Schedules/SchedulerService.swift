import Foundation

/// A tab a run opened, or one found by name, as the scheduler sees it.
public struct ScheduleTab: Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let sessionID: String?
    public let scratch: Bool
    public let busy: Bool

    public init(id: UUID, name: String, sessionID: String?, scratch: Bool, busy: Bool) {
        self.id = id
        self.name = name
        self.sessionID = sessionID
        self.scratch = scratch
        self.busy = busy
    }
}

public struct ScheduleLaunchError: Error, Equatable {
    public let message: String
    public init(message: String) { self.message = message }
}

/// What the scheduler needs from the app beyond running a prompt: open a run's tab, find and
/// close tabs by name, and locate a session's transcript whether its tab is open or not.
@MainActor
public protocol ScheduleBackend: TabRunBackend {
    /// Open a NEW tab named `name` in `cwd`, with `outputSchema` set before its first prompt.
    func openRunTab(name: String, cwd: String, scratch: Bool, provider: String?, model: String?,
                    effort: String?, outputSchema: JSONValue?) -> Result<ScheduleTab, ScheduleLaunchError>
    func tabs(named name: String) -> [ScheduleTab]
    func closeTab(_ id: UUID)
    func transcriptPath(sessionID: String, cwd: String) -> String
}

/// A create-or-update of a schedule, by name; anything left nil keeps its current value. An
/// empty `outputSchema`, `provider`, `model` or `effort` clears it.
public struct ScheduleSpec: Sendable {
    public var name: String
    public var newName: String?
    public var cron: String?
    public var cwd: String?
    public var prompt: String?
    public var scratch: Bool?
    public var outputSchema: String?
    public var provider: String?
    public var model: String?
    public var effort: String?
    public var enabled: Bool?

    public init(name: String, newName: String? = nil, cron: String? = nil, cwd: String? = nil,
                prompt: String? = nil, scratch: Bool? = nil, outputSchema: String? = nil,
                provider: String? = nil, model: String? = nil, effort: String? = nil,
                enabled: Bool? = nil) {
        self.name = name
        self.newName = newName
        self.cron = cron
        self.cwd = cwd
        self.prompt = prompt
        self.scratch = scratch
        self.outputSchema = outputSchema
        self.provider = provider
        self.model = model
        self.effort = effort
        self.enabled = enabled
    }
}

/// Every reason a schedule was refused or a run could not start.
public struct ScheduleProblems: Error, CustomStringConvertible {
    public let problems: [String]
    public init(_ problems: [String]) { self.problems = problems }
    public var description: String { problems.joined(separator: "; ") }
}

/// Runs schedules. Each tick, a schedule whose cron has come due opens a NEW tab named after
/// it, in its folder, and types its prompt; every run leaves a line in the schedule's index
/// (`ScheduleStore`) pointing at the claude session it ran in.
///
/// - A run still going makes the next one of the same schedule skip.
/// - Fires missed while Admiral was closed or the Mac asleep are not replayed: the latest runs
///   once, `late`, and the rest are recorded as one `missed` line.
/// - A run is `timedOut` after `runConfig.turnTimeout` (an hour in the app); its tab stays.
/// - A finished scratch tab an earlier run of the schedule opened is closed before the next
///   run opens its own; any other tab with the name is left alone.
@MainActor
public final class SchedulerService {
    /// A fire more than this far behind the clock runs as `late`.
    static let lateAfter: TimeInterval = 60

    public let store: ScheduleStore
    private let backend: ScheduleBackend
    private let calendar: Calendar
    private let now: () -> Date
    private let runConfig: TabRun.Config
    /// The CC Switch providers a schedule may run on — its custom model.
    private let providers: () -> [CCSwitchProvider]
    /// The run in flight per schedule.
    private var running: [UUID: String] = [:]
    /// Run tasks by run id, kept while their run is in flight — tests await them.
    var tasks: [String: Task<Void, Never>] = [:]

    public init(store: ScheduleStore, backend: ScheduleBackend, calendar: Calendar = .current,
                now: @escaping () -> Date = Date.init, runConfig: TabRun.Config = TabRun.Config(),
                providers: @escaping () -> [CCSwitchProvider] = { CCSwitchCatalog.load() }) {
        self.store = store
        self.backend = backend
        self.calendar = calendar
        self.now = now
        self.runConfig = runConfig
        self.providers = providers
    }

    /// End the runs an Admiral that quit mid-run left `running` in the index. Only the
    /// instance holding the `SchedulerLock` calls this: another instance's in-flight runs look
    /// exactly the same.
    public func endInterruptedRuns() {
        for schedule in store.all() {
            for var run in store.runs(for: schedule.id) where run.status == .running {
                run.status = .failed
                run.endedAt = now()
                run.note = "Admiral closed during the run"
                store.record(run, for: schedule.id)
            }
        }
    }

    // MARK: - Running

    public func tick() {
        let now = now()
        for var schedule in store.all() where schedule.enabled {
            guard let cron = try? CronExpression(schedule.cron),
                  let first = cron.next(after: schedule.lastFire, calendar: calendar), first <= now else { continue }
            var latest = first
            var fires = 1
            while fires < 100_000, let next = cron.next(after: latest, calendar: calendar), next <= now {
                latest = next
                fires += 1
            }
            schedule.lastFire = latest
            store.save(schedule)
            if fires > 1 {
                let missed = fires - 1
                store.record(ScheduleRun(trigger: .cron, status: .missed, scheduledFor: first, startedAt: now,
                                         endedAt: now, note: "\(missed) earlier run\(missed == 1 ? " was" : "s were") "
                                            + "missed while Admiral was closed or the Mac asleep"),
                             for: schedule.id)
            }
            // At the tick's instant, the same as the missed line: the two read back as one fire.
            start(schedule, trigger: now.timeIntervalSince(latest) > Self.lateAfter ? .late : .cron,
                  scheduledFor: latest, at: now)
        }
    }

    /// Start a run of `name` at once.
    public func runNow(name: String) -> Result<ScheduleRun, ScheduleProblems> {
        guard let schedule = schedule(named: name) else { return .failure(ScheduleProblems(["no schedule named \(name)"])) }
        return .success(start(schedule, trigger: .now, scheduledFor: nil, at: now()))
    }

    @discardableResult
    private func start(_ schedule: Schedule, trigger: ScheduleRun.Trigger, scheduledFor: Date?,
                       at now: Date) -> ScheduleRun {
        var run = ScheduleRun(trigger: trigger, status: .running, scheduledFor: scheduledFor, startedAt: now)
        guard running[schedule.id] == nil else {
            return end(run, as: .skipped, note: "the previous run was still going", for: schedule)
        }
        closeFinishedRunTabs(of: schedule)
        var schema: JSONValue?
        if let text = schedule.outputSchema {
            guard case let .success(parsed) = BridgeCore.parseStrictSchema(text) else {
                return end(run, as: .failed, note: "the output schema no longer parses", for: schedule)
            }
            schema = parsed
        }
        // schedules/<id>.json is a file anyone with the user's access can edit after `set`
        // checked it, and these two reach claude's command line: re-check them every run.
        guard let model = ScheduleModel(rawValue: schedule.model ?? ScheduleModel.default.rawValue) else {
            return end(run, as: .failed, note: "the model is not one of \(ScheduleModel.spelling)", for: schedule)
        }
        let effort = schedule.effort.flatMap { $0.isEmpty ? nil : $0 }
        if let effort, ScheduleEffort(rawValue: effort) == nil {
            return end(run, as: .failed, note: "the effort is not one of \(ScheduleEffort.spelling)", for: schedule)
        }
        switch backend.openRunTab(name: schedule.name, cwd: schedule.cwd, scratch: schedule.scratch,
                                  provider: schedule.provider, model: model.rawValue,
                                  effort: effort, outputSchema: schema) {
        case let .failure(error):
            return end(run, as: .failed, note: error.message, for: schedule)
        case let .success(tab):
            run.callsign = tab.name
            run.sessionID = tab.sessionID
            store.record(run, for: schedule.id)
            running[schedule.id] = run.id
            let started = run
            tasks[run.id] = Task { [weak self] in await self?.drive(started, in: tab, of: schedule) }
            return run
        }
    }

    /// Type the prompt and wait out the turn, then close the run's line.
    private func drive(_ started: ScheduleRun, in tab: ScheduleTab, of schedule: Schedule) async {
        let tabRun = TabRun(backend: backend, config: runConfig)
        let path = backend.transcriptPath(tabID: tab.id)
            ?? tab.sessionID.map { backend.transcriptPath(sessionID: $0, cwd: schedule.cwd) } ?? ""
        let status: ScheduleRun.Status
        var note: String?
        if await tabRun.deliver(schedule.prompt, tabID: tab.id, path: path, baselineUserCount: 0) {
            let structured = schedule.outputSchema != nil
            let turn = await tabRun.awaitTurn(tabID: tab.id, path: path, fromOffset: 0,
                                              slot: structured ? .output : nil)
            if turn.agentExited {
                status = .failed
                note = "the agent exited during the turn"
            } else if turn.timedOut {
                status = .timedOut
                note = "still going after \(Int(runConfig.turnTimeout / 60)) minutes"
            } else if structured, backend.structuredOutputState(tabID: tab.id, type: .output)?.status != .fulfilled {
                status = .failed
                note = "the turn ended without its structured output"
            } else {
                status = .succeeded
            }
        } else {
            status = .failed
            note = "the prompt never reached claude"
        }
        running[schedule.id] = nil
        tasks[started.id] = nil
        // A schedule deleted mid-run takes its history with it; don't write it back.
        guard store.all().contains(where: { $0.id == schedule.id }) else { return }
        end(started, as: status, note: note, for: schedule)
    }

    @discardableResult
    private func end(_ run: ScheduleRun, as status: ScheduleRun.Status, note: String?, for schedule: Schedule) -> ScheduleRun {
        var run = run
        run.status = status
        run.endedAt = now()
        run.note = note
        store.record(run, for: schedule.id)
        return run
    }

    /// Close finished scratch tabs this schedule's earlier runs opened, so the new run's tab is
    /// the one with the name. A regular tab, or one the schedule didn't open, stays.
    private func closeFinishedRunTabs(of schedule: Schedule) {
        let ours = Set(store.runs(for: schedule.id).compactMap(\.sessionID))
        for tab in backend.tabs(named: schedule.name)
        where tab.scratch && !tab.busy && tab.sessionID.map(ours.contains) == true {
            backend.closeTab(tab.id)
        }
    }

    // MARK: - Reading

    /// A schedule as listed: what its cron means, when it next runs, how its last run went.
    public struct Overview: Sendable {
        public let schedule: Schedule
        public let summary: String
        public let next: Date?
        public let lastRun: ScheduleRun?
        /// Its latest fire went wrong: the run failed or timed out, or fires were missed on
        /// the way to it. A paused schedule never does — pausing is how its trouble is set aside.
        public let needsAttention: Bool
    }

    public func overview() -> [Overview] {
        store.all().map { schedule in
            let cron = try? CronExpression(schedule.cron)
            let runs = store.runs(for: schedule.id)
            return Overview(schedule: schedule, summary: cron?.summary ?? schedule.cron,
                            next: schedule.enabled ? nextFires(of: schedule, count: 1).first : nil,
                            lastRun: runs.first,
                            needsAttention: schedule.enabled && Self.latestFireWentWrong(runs))
        }
    }

    /// The latest fire is every run sharing the newest start: a tick that finds missed fires
    /// records the `missed` line and starts the late run at one instant, so `missed` is never
    /// the newest line on its own.
    static func latestFireWentWrong(_ runs: [ScheduleRun]) -> Bool {
        guard let newest = runs.first else { return false }
        return runs.prefix { $0.startedAt == newest.startedAt }
            .contains { [.failed, .timedOut, .missed].contains($0.status) }
    }

    /// The sidebar's line under "Schedules": `lead` (the one enabled schedule's name, or how
    /// many are enabled) and the countdown to the soonest fire.
    public struct SidebarLine: Equatable, Sendable {
        public let lead: String
        public let countdown: String?
    }

    /// One enabled schedule names itself — `weekly-report · 3d 23h`; more say how many and
    /// when the first fires — `3 active · next in 14m`, since one name would stand for all of
    /// them; none enabled, no line. Paused schedules never count.
    public static func sidebarLine(_ overviews: [Overview], now: Date) -> SidebarLine? {
        let enabled = overviews.filter(\.schedule.enabled)
        let soonest = enabled.compactMap(\.next).min().map { countdown(to: $0, from: now) }
        switch enabled.count {
        case 0: return nil
        case 1: return SidebarLine(lead: enabled[0].schedule.name, countdown: soonest)
        default: return SidebarLine(lead: "\(enabled.count) active", countdown: soonest.map { "next in \($0)" })
        }
    }

    /// Why a schedule's output schema text is refused, or nil: empty text means no schema, and
    /// anything else must be a strict JSON Schema. The check `set` makes, for an editor to show live.
    public static func outputSchemaProblem(_ text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, case let .failure(message) = BridgeCore.parseStrictSchema(text) else { return nil }
        return message
    }

    /// `2h 14m` until `date`, in whole minutes rounded down: days and hours past a day, hours
    /// and minutes past an hour, minutes under that, `<1m` in the last minute or once it is due.
    public static func countdown(to date: Date, from now: Date) -> String {
        let minutes = Int(date.timeIntervalSince(now) / 60)
        guard minutes >= 1 else { return "<1m" }
        let days = minutes / 1440, hours = minutes % 1440 / 60, mins = minutes % 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return mins > 0 ? "\(hours)h \(mins)m" : "\(hours)h" }
        return "\(mins)m"
    }

    /// The schedule's next `count` fire times from now.
    public func nextFires(of schedule: Schedule, count: Int) -> [Date] {
        guard let cron = try? CronExpression(schedule.cron) else { return [] }
        var fires: [Date] = []
        var after = max(now(), schedule.lastFire)
        while fires.count < count, let next = cron.next(after: after, calendar: calendar) {
            fires.append(next)
            after = next
        }
        return fires
    }

    /// Runs, newest first — one schedule's, or every schedule's.
    public func history(name: String?, limit: Int) -> Result<[(schedule: Schedule, run: ScheduleRun)], ScheduleProblems> {
        let schedules: [Schedule]
        if let name, !name.isEmpty {
            guard let one = schedule(named: name) else { return .failure(ScheduleProblems(["no schedule named \(name)"])) }
            schedules = [one]
        } else {
            schedules = store.all()
        }
        let runs = schedules.flatMap { schedule in store.runs(for: schedule.id).map { (schedule: schedule, run: $0) } }
        return .success(Array(runs.sorted { $0.run.startedAt > $1.run.startedAt }.prefix(max(limit, 1))))
    }

    /// One run, with what it did read from its session's transcript.
    public struct RunDetail: Sendable {
        public let schedule: Schedule
        public let run: ScheduleRun
        public let transcriptPath: String?
        public let result: ScheduleTranscript.Result?
    }

    public func detail(runID: String) -> RunDetail? {
        for schedule in store.all() {
            guard let run = store.runs(for: schedule.id).first(where: { $0.id == runID }) else { continue }
            let path = run.sessionID.map { backend.transcriptPath(sessionID: $0, cwd: schedule.cwd) }
            let result = path.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }.map(ScheduleTranscript.result)
            return RunDetail(schedule: schedule, run: run, transcriptPath: path, result: result)
        }
        return nil
    }

    /// `2026-10-02 09:00`, in the scheduler's (the Mac's) time zone.
    public func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    // MARK: - Setting

    public func schedule(named name: String) -> Schedule? {
        let key = StationName.sanitize(name)
        return store.all().first { $0.name.caseInsensitiveCompare(key) == .orderedSame }
    }

    /// Create the schedule `spec.name`, or update it. The name follows the tab-name rule, since
    /// it is the name of every tab a run opens; every problem is listed.
    public func set(_ spec: ScheduleSpec) -> Result<Schedule, ScheduleProblems> {
        let existing = schedule(named: spec.name)
        var problems: [String] = []

        let name = StationName.sanitize(spec.newName ?? spec.name)
        if name.isEmpty {
            problems.append("the name is empty once made a valid tab name")
        } else if store.all().contains(where: { $0.id != existing?.id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            problems.append("a schedule named \(name) already exists")
        }

        let cron = spec.cron?.trimmingCharacters(in: .whitespacesAndNewlines) ?? existing?.cron
        if let cron {
            do {
                if try CronExpression(cron).next(after: now(), calendar: calendar) == nil {
                    problems.append("the cron '\(cron)' never fires")
                }
            } catch {
                problems.append("cron: \(error)")
            }
        } else {
            problems.append("a cron is required")
        }

        let cwd = spec.cwd.map { ($0.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath }
            ?? existing?.cwd
        var isDir: ObjCBool = false
        if let cwd {
            if !FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir) || !isDir.boolValue {
                problems.append("the folder does not exist: \(cwd)")
            }
        } else {
            problems.append("a folder (cwd) is required")
        }

        let prompt = spec.prompt.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? existing?.prompt
        if prompt?.isEmpty ?? true { problems.append("a prompt is required") }

        var schema = existing?.outputSchema
        if let text = spec.outputSchema?.trimmingCharacters(in: .whitespacesAndNewlines) {
            if let problem = Self.outputSchemaProblem(text) {
                problems.append(problem)
            } else {
                schema = text.isEmpty ? nil : text
            }
        }

        // A custom model: checked now, and resolved again at each run so a token rotated in
        // CC Switch reaches the next run.
        var provider = existing?.provider
        if let key = spec.provider?.trimmingCharacters(in: .whitespacesAndNewlines) {
            if key.isEmpty {
                provider = nil
            } else if case let .failure(error) = CCSwitchCatalog.resolve(key, from: providers) {
                problems.append(error.message)
            } else {
                provider = key
            }
        }

        // The claude model and effort every run launches with, by the CLI's own spellings.
        var model = existing?.model
        if let text = spec.model?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            if text.isEmpty {
                model = nil
            } else if ScheduleModel(rawValue: text) == nil {
                problems.append("the model must be one of \(ScheduleModel.spelling)")
            } else {
                model = text
            }
        }
        var effort = existing?.effort
        if let text = spec.effort?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            if text.isEmpty {
                effort = nil
            } else if ScheduleEffort(rawValue: text) == nil {
                problems.append("the effort must be one of \(ScheduleEffort.spelling)")
            } else {
                effort = text
            }
        }

        guard problems.isEmpty, let cron, let cwd, let prompt else { return .failure(ScheduleProblems(problems)) }
        var schedule = existing ?? Schedule(name: name, cron: cron, cwd: cwd, prompt: prompt, lastFire: now())
        // A new cron, or a schedule switched back on, starts from now: no catching up on the gap.
        if cron != schedule.cron || (spec.enabled == true && !schedule.enabled) { schedule.lastFire = now() }
        schedule.name = name
        schedule.cron = cron
        schedule.cwd = cwd
        schedule.prompt = prompt
        schedule.scratch = spec.scratch ?? schedule.scratch
        schedule.outputSchema = schema
        schedule.provider = provider
        schedule.model = model
        schedule.effort = effort
        schedule.enabled = spec.enabled ?? schedule.enabled
        store.save(schedule)
        return .success(schedule)
    }

    public func delete(name: String) -> Bool {
        guard let schedule = schedule(named: name) else { return false }
        store.delete(schedule.id)
        return true
    }
}
