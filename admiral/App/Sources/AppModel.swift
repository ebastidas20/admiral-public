import Foundation
import SwiftUI
import AppKit
import Combine
import CoreSpotlight
import AuthenticationServices
import SwiftTerm
import AdmiralCore
import Darwin
import IOKit.pwr_mgt

/// Wires the headless core (SessionManager + BridgeCore + MCP) to the app and the
/// SwiftTerm host, and drives the periodic refresh.
enum ThemeMode: String { case auto, light, dark }

/// Which kind of session the shared New… form will create: a `claude` session
/// ("New Claude Code") or a plain login `zsh` shell ("New Bash").
enum NewSessionMode { case claudeCode, bash }

@MainActor
final class AppModel: ObservableObject {
    let host: SwiftTermHost
    let sessions: SessionManager
    let bridge: BridgeCore
    /// Prompts sent to new tabs on a cron; the `schedule_*` tools drive it too.
    let scheduler: SchedulerService
    /// Held while this instance runs the support folder's schedules (`SchedulerLock`): a dev
    /// build beside the installed app must not open every run a second time.
    private var schedulerLock: SchedulerLock?
    /// The Schedules sheet.
    @Published var showSchedules = false
    /// Whether this instance runs the schedules (the probe reports it).
    var holdsSchedules: Bool { schedulerLock != nil }
    let mcp: MCPServer
    private var bridgeSocket: BridgeSocketServer?
    /// The session bridge (127.0.0.1:4142 `/mcp/session`): how an ACP tab's agent, which cannot
    /// reach `bridgeSocket`, calls the session tools. Up while any ACP agent is configured.
    private var sessionBridgeServer: SessionMCPHTTPServer?
    private var acpAgentsObserver: NSObjectProtocol?
    /// Parks `tools/call` from API tool tabs. Same broker `SessionManager` hands the
    /// Anthropic endpoint; the `client` MCP process is the only other side of this socket.
    private var clientToolSocket: ClientToolSocketServer?
    /// Posts claude's terminal notifications (OSC 9 / 777) to macOS Notification Center.
    let notifications = NotificationService()
    /// Persists Settings → Watchdog (trigger rules + thresholds). Profile-aware like the
    /// tab stores; the service re-reads it every tick, so edits apply live.
    let watchdogConfigStore: WatchdogConfigStore
    private let watchdogStateStore: WatchdogStateStore
    let goalsNudgeConfigStore: GoalsNudgeConfigStore
    /// Feature flags + Tickets settings from `<support dir>/config.json`. Loaded at
    /// startup; only the `tickets` section is rewritten live (Settings → Tickets).
    @Published private(set) var config: AdmiralConfig
    /// The goals a peer set on each session — read by the panel, written by the bridge tool
    /// and the nudge's answers.
    let goalsStore: GoalsStore
    /// Group chats (`features.groups`; see AppModel+Groups.swift). Built always, used only
    /// while the flag is on.
    let groupStore: GroupStore
    let groupService: GroupService
    /// Where groups sit among the tabs in the sidebar.
    let sidebarOrderStore: SidebarOrderStore
    /// How far the human has read each group (the sidebar's unread dot). In this instance's
    /// defaults, never in the group files.
    let groupSeen: GroupSeenCursor
    /// The group shown in the detail pane. Selecting a tab clears it; selecting a group
    /// leaves `sessions.selectedID` alone.
    @Published var selectedGroupID: UUID?
    /// Presents the New Group sheet.
    @Published var newGroupSheet: NewGroupRequest?
    /// One idle truth, shared by every nudge below: whichever speaks first wakes the
    /// session, which puts the others back under their threshold. That is the arbitration.
    private let idleClock = IdleClock()
    /// Keeps a session driving a standing directive (e.g. "/drive-ticket to PROD"):
    /// idle → forced-format probe → templated nag, until the session reports done.
    /// Lazy: it captures `sessions`, which init assigns after the stores.
    private(set) lazy var watchdog = WatchdogService(
        manager: sessions,
        stateStore: watchdogStateStore,
        configProvider: { [watchdogConfigStore] in watchdogConfigStore.load() },
        idle: idleClock,
        notify: { [weak self] id, title, body in
            self?.notifications.post(kind: .done, title: title, body: body, sessionID: id)
        }
    )
    /// Chases the session's goals the same way: idle → goals probe → nag, until every goal
    /// is reported met.
    private(set) lazy var goalsNudge = GoalsService(
        manager: sessions,
        goalsStore: goalsStore,
        configProvider: { [goalsNudgeConfigStore] in goalsNudgeConfigStore.load() },
        idle: idleClock,
        notify: { [weak self] id, title, body in
            self?.notifications.post(kind: .done, title: title, body: body, sessionID: id)
        }
    )
    /// Gives a tab an icon from the start of its first prompt, picked by the on-device model,
    /// unless the user has set one.
    private(set) lazy var autoIcon = AutoIconService(
        manager: sessions,
        picker: AppleIntelligenceIconPicker(),
        symbols: AvatarEditorPopover.symbols
    )
    /// Tells a session when a PR on a repo it has written to moves — checks red, approval in,
    /// mergeable, merged. Gated on that session's watchdog being armed, so Admiral polls
    /// GitHub for the sessions being driven to done and for no others.
    private(set) lazy var prWatch = PRWatchService(
        manager: sessions,
        store: PRWatchStore(base: sessions.supportDir),
        idle: idleClock,
        isWatched: { [weak self] sid in self?.isWatchdogWatching(sid) ?? false },
        fetch: { [weak self] session, root, branches in
            guard let github = await self?.github(for: session) else { return [] }
            var prs: [PRStatus] = []
            var seen = Set<Int>()
            for branch in branches {
                guard let pr = await github.prStatus(branch: branch, cwd: root),
                      !seen.contains(pr.number) else { continue }
                seen.insert(pr.number)
                prs.append(pr)
            }
            return prs
        }
    )
    /// A watchdog is on and armed for this claude session — the one answer behind PR watch's
    /// gate and the bridge taking an unasked watchdog report.
    func isWatchdogWatching(_ sid: String) -> Bool {
        guard watchdogConfigStore.load().enabled, watchdog.sessionEnabled(sid) else { return false }
        return watchdog.phase(forSession: sid) != .disarmed
    }
    private let github = GitHubService()
    /// ACP tabs' gh, each run through that tab's exec runner (its environment's gh and login),
    /// by tab id. All share `GitHubService.sharedLimiter`, so the gh rate cap stays app-wide.
    private var acpGitHub: [UUID: GitHubService] = [:]

    /// The gh to ask about `session`'s PRs: the Mac's for a PTY tab; the tab's own (through its
    /// exec) for an ACP tab whose record enables PR watch; nil otherwise.
    func github(for session: AgentSession) -> GitHubService? {
        guard session.canQueryPRs else { return nil }
        guard session.backend != .pty else { return github }
        if let made = acpGitHub[session.id] { return made }
        guard let runner = sessions.acpRunner(for: session) else { return nil }
        let made = GitHubService(runner: runner)
        // Drop closed tabs' instances as new ones are made (a reload is a new tab id).
        let open = Set(sessions.sessions.map(\.id))
        acpGitHub = acpGitHub.filter { open.contains($0.key) }
        acpGitHub[session.id] = made
        return made
    }
    /// Merge-readiness of the selected session's PR (refreshed periodically). nil = none.
    @Published var prStatus: PRStatus?
    private var prSession: UUID?
    private var prBranch: String?
    private var prFetchInFlight = false
    private var lastPRFetch = Date.distantPast
    /// The right-side "Footprint" panel (default hidden; the open/closed state is persisted
    /// like the sidebar/theme, so it reopens on relaunch). Toggled from the toolbar / ⇧⌘R.
    /// `-uiTestPanelOpen` forces it open for rendered-UI tests. It's read in the property
    /// initializer, not assigned afterwards, so `didSet` never fires and the flag cannot
    /// leak into the real app's persisted preference.
    @Published var showTouchedReposPanel: Bool =
        UserDefaults.standard.bool(forKey: "admiral.showFootprintPanel")
            || ProcessInfo.processInfo.arguments.contains("-uiTestPanelOpen") {
        didSet { UserDefaults.standard.set(showTouchedReposPanel, forKey: "admiral.showFootprintPanel") }
    }
    private var touchedPRFetch: [String: Date] = [:]   // repoRoot → last fetch
    private var touchedPRBranch: [String: String] = [:]  // repoRoot → branch-set signature last fetched for
    private var touchedPRInFlight: Set<String> = []
    /// Tickets (Footprint): per-session ledger signature last scanned, and per-key status
    /// cache + 30s fetch throttle. Status is only fetched while Jira is connected.
    private var ticketScanSignature: [UUID: String] = [:]
    private var ticketScanInFlight: Set<UUID> = []
    private var ticketStatusCache: [String: TicketRef] = [:]
    private var ticketStatusFetch: [String: Date] = [:]
    private var ticketStatusInFlight = false
    /// Jira OAuth tokens are present in the Keychain (`TicketsAuthStore`).
    @Published private(set) var ticketsConnected = TicketsAuthStore.isConnected
    /// The Jira client secret is present in the Keychain.
    @Published private(set) var jiraHasClientSecret = TicketsAuthStore.clientSecret != nil
    @Published private(set) var jiraConnecting = false
    @Published var jiraAuthError: String?
    private var jiraAuth: JiraAuthSession?
    /// Presents the New Claude Code / New Bash form (agent name, folder).
    @Published var showNewTerminal = false
    /// Which kind of session that form will create — drives its title and launch recipe.
    @Published var newSessionMode: NewSessionMode = .claudeCode
    /// Scratch tab being promoted (drives the promote sheet in the sidebar).
    @Published var promotingSession: AgentSession?

    /// ⌘S: open the promote sheet for the selected tab, when it is a scratch tab.
    func promoteSelected() {
        if let tab = sessions.selectedScratchTab { requestPromote(tab.id) }
    }

    func requestPromote(_ id: UUID) {
        promotingSession = sessions.sessions.first { $0.id == id && $0.scratch }
    }

    /// Promote + apply the sheet's name. Color/icon stay gray/sparkles until the
    /// user edits them in the avatar popover, like any tab.
    func promote(_ id: UUID, name: String) {
        sessions.promote(id)
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { sessions.rename(id, to: trimmed) }
    }
    /// Left bar collapsed (icons only) vs expanded (icons + text). Persisted.
    @Published var sidebarCollapsed: Bool = UserDefaults.standard.bool(forKey: "admiral.sidebarCollapsed") {
        didSet { UserDefaults.standard.set(sidebarCollapsed, forKey: "admiral.sidebarCollapsed") }
    }
    /// Appearance: follow system / light / dark. Persisted.
    @Published var themeMode: ThemeMode =
        ThemeMode(rawValue: UserDefaults.standard.string(forKey: "admiral.themeMode") ?? "") ?? .auto {
        didSet {
            UserDefaults.standard.set(themeMode.rawValue, forKey: "admiral.themeMode")
            applyTheme()
        }
    }

    /// SwiftUI re-themes itself from `preferredColorScheme`; the terminals hold baked-in
    /// colors, so they have to be told (existing ones included). The Stealth flag changes the
    /// palette under an unchanged appearance, so that needs its own re-apply.
    private func applyTheme() {
        let paletteChanged = Theme.usesStealthPalette != config.features.stealthTheme
        Theme.usesStealthPalette = config.features.stealthTheme
        host.appearance = Theme.appearance(for: themeMode)
        if paletteChanged { host.reapplyColors() }
    }

    var preferredColorScheme: ColorScheme? {
        switch themeMode { case .auto: nil; case .light: .light; case .dark: .dark }
    }
    /// Settings → Notifications master switch: gates EVERY native notification (terminal OSC,
    /// hooks, the bridge `notify` tool, watchdog and goals nudges). The per-kind toggles live
    /// under `admiral.notify.*` (`NotificationPolicy`); `NotificationService` checks both.
    /// Persisted; default on.
    @Published var notificationsEnabled: Bool =
        UserDefaults.standard.object(forKey: NotificationPolicy.masterKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(notificationsEnabled, forKey: NotificationPolicy.masterKey) }
    }
    /// Cycle auto → light → dark → auto.
    func cycleTheme() {
        switch themeMode { case .auto: themeMode = .light; case .light: themeMode = .dark; case .dark: themeMode = .auto }
    }

    /// "Keep awake" — while on, stops the display from idle-sleeping (`caffeinate -d`) AND keeps
    /// the Mac counted as "user active" (`caffeinate -u`): a repeating timer declares local user
    /// activity, which resets the HID idle timer. That matters for Universal Control, which drops
    /// ~60s after this Mac sees no local input (the idle Mac switches its Bluetooth Continuity
    /// signal to an idle mode the other Mac doesn't recognize); `-d` alone doesn't reset it.
    /// The display assertion is a `ProcessInfo` activity token (no subprocess). The on/off
    /// preference persists across relaunch (`admiral.keepAwake`); quitting still releases the
    /// assertions, and a saved-on state re-acquires them on the next plain launch.
    @Published private(set) var keepAwake = false
    private var sleepAssertion: NSObjectProtocol?
    private var userActivityTimer: Timer?
    private var userActivityAssertionID: IOPMAssertionID = IOPMAssertionID(0)
    private static let userActivityInterval: TimeInterval = 20
    private static let keepAwakeKey = "admiral.keepAwake"

    func toggleKeepAwake() {
        setKeepAwake(!keepAwake)
    }

    /// Apply keep-awake and persist. Re-acquiring when already on is a no-op for the token.
    func setKeepAwake(_ on: Bool) {
        if on {
            if sleepAssertion == nil {
                sleepAssertion = ProcessInfo.processInfo.beginActivity(
                    options: .idleDisplaySleepDisabled, reason: "Admiral: keep awake")
            }
            startUserActivityTimer()
            keepAwake = true
        } else {
            if let token = sleepAssertion {
                ProcessInfo.processInfo.endActivity(token)
                sleepAssertion = nil
            }
            stopUserActivityTimer()
            keepAwake = false
        }
        UserDefaults.standard.set(keepAwake, forKey: Self.keepAwakeKey)
    }

    /// Declare local user activity now and every ~20s (idempotent). Reuses one assertion ID, so
    /// each call refreshes the same `UserIsActive` assertion rather than stacking new ones.
    private func startUserActivityTimer() {
        guard userActivityTimer == nil else { return }
        declareUserActivity()
        let timer = Timer(timeInterval: Self.userActivityInterval, repeats: true) { [weak self] _ in
            self?.declareUserActivity()
        }
        RunLoop.main.add(timer, forMode: .common)
        userActivityTimer = timer
    }

    private func declareUserActivity() {
        IOPMAssertionDeclareUserActivity("Admiral: keep awake" as CFString,
                                         kIOPMUserActiveLocal, &userActivityAssertionID)
    }

    /// Invalidate the timer and release the user-activity assertion. Does not touch the
    /// persisted preference, so it is safe on quit.
    private func stopUserActivityTimer() {
        userActivityTimer?.invalidate()
        userActivityTimer = nil
        if userActivityAssertionID != IOPMAssertionID(0) {
            IOPMAssertionRelease(userActivityAssertionID)
            userActivityAssertionID = IOPMAssertionID(0)
        }
    }

    /// Re-arm keep-awake from UserDefaults after a plain relaunch (no activity token survives quit).
    private func restoreKeepAwakeIfNeeded() {
        guard UserDefaults.standard.bool(forKey: Self.keepAwakeKey) else { return }
        setKeepAwake(true)
    }

    /// The Anthropic-compatible API server. nil port = off. The enabled flag persists
    /// so the server comes back up on relaunch — clients keep a stable base URL across
    /// app restarts.
    @Published private(set) var apiServerPort: UInt16?
    private var apiServer: AnthropicHTTPServer?
    private static let apiServerEnabledKey = "admiral.apiServerEnabled"  // "admiral." prefix = repo convention

    /// Preferred API-server port (Settings → Bridge & API). The server binds this, falling
    /// back to an ephemeral port when it's busy. Setting it while the server runs restarts
    /// the server, so the change applies immediately and the UI shows the real bound port.
    @Published var apiServerPreferredPort: UInt16 =
        (UserDefaults.standard.object(forKey: "admiral.apiServerPort") as? Int)
            .flatMap { UInt16(exactly: $0) } ?? 4141 {
        didSet {
            UserDefaults.standard.set(Int(apiServerPreferredPort), forKey: "admiral.apiServerPort")
            if apiServerPort != nil { stopAPIServer(); startAPIServer() }
        }
    }

    /// Extra `Host` names the API server trusts (Settings → Bridge & API). Docker Desktop
    /// clients reach the host loopback as `host.docker.internal`. Stored as a string array and
    /// applied to `TrustedHosts` on every change; empty by default. An older comma-separated
    /// string (or one written with `defaults write -string`) is read once and rewritten.
    static let trustedHostsKey = "admiral.trustedHosts"
    @Published var trustedHosts: [String] = {
        let stored = TrustedHosts.migrate(stored: UserDefaults.standard.object(forKey: AppModel.trustedHostsKey))
        UserDefaults.standard.set(stored, forKey: AppModel.trustedHostsKey)
        TrustedHosts.set(stored)
        return stored
    }() {
        didSet {
            UserDefaults.standard.set(trustedHosts, forKey: Self.trustedHostsKey)
            TrustedHosts.set(trustedHosts)
        }
    }

    /// Group chat: an untagged message goes to the members a model scores at or above the
    /// threshold, or to the highest scorer (Settings → Bridge & API). Off = every member.
    static let groupRelevanceEnabledKey = "admiral.groupRelevanceEnabled"
    @Published var groupRelevanceEnabled: Bool =
        UserDefaults.standard.object(forKey: AppModel.groupRelevanceEnabledKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(groupRelevanceEnabled, forKey: Self.groupRelevanceEnabledKey) }
    }
    static let groupRelevanceThresholdKey = "admiral.groupRelevanceThreshold"
    @Published var groupRelevanceThreshold: Double =
        UserDefaults.standard.object(forKey: AppModel.groupRelevanceThresholdKey) as? Double
            ?? GroupRelevance.defaultThreshold {
        didSet { UserDefaults.standard.set(groupRelevanceThreshold, forKey: Self.groupRelevanceThresholdKey) }
    }

    func toggleAPIServer() {
        guard config.features.apiServer else { return }
        let enable = apiServerPort == nil
        if enable { startAPIServer() } else { stopAPIServer() }
        // Intent, not outcome: a bind can still fail (port unavailable).
        UserDefaults.standard.set(enable, forKey: Self.apiServerEnabledKey)
    }

    /// The API server binds its port immediately and never waits for the Keychain. Routes do not
    /// require an operator token. The token is still resolved in the background
    /// (`recheckOperatorToken`) and kept in memory; that work never gates a request.
    private func startAPIServer() {
        guard config.features.apiServer else { return }
        // A legacy token file is a fast local read that never blocks: serve it straight away.
        if operatorMCPToken.isEmpty, let token = OperatorTokenStore.fileToken(base: sessions.supportDir) {
            operatorMCPToken = token
        }
        launchAPIServer()
        // Toggled on later with no token yet: resolve in the background (launch does this itself).
        if operatorMCPToken.isEmpty, operatorTokenMirrorStatus != .checking { recheckOperatorToken() }
    }

    private func launchAPIServer() {
        guard apiServer == nil else { return }
        let mcpEndpoint = OperatorMCPEndpoint(mcp: mcp)
        let server = AnthropicHTTPServer(
            endpoint: AnthropicEndpoint(backend: sessions),
            mcpEndpoint: mcpEndpoint,
            eventsEndpoint: SessionEventsEndpoint(source: sessions)
        )
        guard let port = server.start(preferredPort: apiServerPreferredPort) else { return }
        apiServer = server
        apiServerPort = port
    }

    private func stopAPIServer() {
        apiServer?.stop()
        apiServer = nil
        apiServerPort = nil
    }

    // MARK: - Operator token (Keychain; not required by any route)

    /// Operator token kept in the Keychain. Routes do not check it. Deliberately NOT published —
    /// no view can show it.
    private let operatorTokenProvider = OperatorTokenProvider()
    private var operatorMCPToken: String {
        get { operatorTokenProvider.token }
        set { operatorTokenProvider.token = newValue }
    }

    /// The token lives in the Keychain; a legacy plaintext file is migrated into it at startup
    /// (`OperatorTokenStore.migrateLegacyTokenFile`): the FILE value (the one clients use) wins,
    /// is written to the Keychain, verified by read-back, and the file is deleted. All Keychain
    /// access is off-main. Steady-state reads wait ≤ `steadyTimeout` (2 s); first-run / migration
    /// calls run in the background and wait up to `patientTimeout` (120 s) so a human can answer a
    /// Keychain access prompt — meanwhile the API server keeps serving the file value. If the wait
    /// still expires, a timed-out resolution is retried every 15 s for ~5 min (the user clicking
    /// Allow late), plus the Recheck button.
    /// Scoped to the isolation profile (`token.<profile>`), so a test or second instance can
    /// never touch the main instance's token. Built in `init` once the profile is known.
    private let operatorTokenMirror: GuardedOperatorTokenMirror
    private let operatorTokenQueue = DispatchQueue(label: "admiral.operator-token", qos: .utility)
    @Published private(set) var operatorTokenMirrorStatus: OperatorTokenMirrorStatus = .checking
    private let operatorTokenRetryPolicy = OperatorTokenRetryPolicy()
    private var operatorTokenRetryAttempts = 0
    /// Bumped by every user-initiated action; pending automatic retries from an older generation
    /// do nothing.
    private var operatorTokenRetryGeneration = 0

    /// Run `work` (Keychain + legacy-file I/O) serially on a background queue, then hand the
    /// result to `done` on the main actor. `patient` selects the long-wait mirror for the
    /// first-run / migration calls (the steady-state mirror otherwise).
    private func runTokenWork(
        _ work: @escaping @Sendable (URL, OperatorTokenMirror, OperatorTokenMirror) -> OperatorTokenStore.Resolution,
        patient: Bool = true,
        done: @escaping @MainActor (OperatorTokenStore.Resolution) -> Void
    ) {
        let base = sessions.supportDir
        let short: OperatorTokenMirror = operatorTokenMirror
        let long: OperatorTokenMirror = patient
            ? operatorTokenMirror.waiting(upTo: OperatorTokenStore.patientTimeout) : short
        operatorTokenQueue.async {
            let r = work(base, short, long)
            DispatchQueue.main.async { MainActor.assumeIsolated { done(r) } }
        }
    }

    /// Adopt a resolution: publish the status, and when the effective token changed, swap it in
    /// (restarting a running server so `/mcp` and `/events` accept it).
    private func applyOperatorResolution(_ r: OperatorTokenStore.Resolution) {
        operatorTokenMirrorStatus = r.mirror
        scheduleOperatorTokenRetryIfNeeded(r.mirror)
        guard !r.token.isEmpty, r.token != operatorMCPToken else { return }
        operatorMCPToken = r.token  // the running server reads it per request: no restart needed
    }

    /// A timed-out resolution is an unanswered Keychain prompt: try again in 15 s (up to the
    /// policy's limit) so Allow takes effect without the user touching anything.
    private func scheduleOperatorTokenRetryIfNeeded(_ status: OperatorTokenMirrorStatus) {
        guard operatorTokenRetryPolicy.shouldRetry(status: status, attempt: operatorTokenRetryAttempts) else {
            if !status.isRetryable { operatorTokenRetryAttempts = 0 }
            return
        }
        operatorTokenRetryAttempts += 1
        let generation = operatorTokenRetryGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + operatorTokenRetryPolicy.interval) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.operatorTokenRetryGeneration == generation else { return }
                self.runTokenWork({ OperatorTokenStore.resolve(base: $0, mirror: $1, patient: $2) }) { [weak self] in
                    self?.applyOperatorResolution($0)
                }
            }
        }
    }

    /// Settings → Recheck (and launch): re-resolve (and retry any legacy-file migration) off-main.
    func recheckOperatorToken() {
        operatorTokenRetryGeneration += 1
        operatorTokenRetryAttempts = 0
        operatorTokenMirrorStatus = .checking
        runTokenWork({ OperatorTokenStore.resolve(base: $0, mirror: $1, patient: $2) }) { [weak self] in
            self?.applyOperatorResolution($0)
        }
    }

    /// Minutes a scratch tab may sit idle (with no open goals) before the reaper closes it
    /// (Settings → Bridge & API). Persisted; the reap sweep re-reads it via the provider
    /// handed to `SessionManager`, so a change applies at the next tick.
    static let scratchTabIdleMinutesKey = "admiral.scratchTabIdleMinutes"
    /// Where the value lived while these were called temp tabs; read as a fallback so an
    /// existing setting carries over, and dropped on the first write.
    static let legacyTempTabIdleMinutesKey = "admiral.tempTabIdleMinutes"
    static let scratchTabIdleMinutesDefault = 30
    static var storedScratchTabIdleMinutes: Int {
        let d = UserDefaults.standard
        return d.object(forKey: scratchTabIdleMinutesKey) as? Int
            ?? d.object(forKey: legacyTempTabIdleMinutesKey) as? Int
            ?? scratchTabIdleMinutesDefault
    }
    @Published var scratchTabIdleMinutes: Int = AppModel.storedScratchTabIdleMinutes {
        didSet {
            UserDefaults.standard.set(scratchTabIdleMinutes, forKey: Self.scratchTabIdleMinutesKey)
            UserDefaults.standard.removeObject(forKey: Self.legacyTempTabIdleMinutesKey)
        }
    }
    /// Off = scratch tabs are never closed automatically (Settings → Bridge & API).
    static let scratchAutoCloseKey = "admiral.scratchAutoClose"
    @Published var scratchAutoClose: Bool =
        UserDefaults.standard.object(forKey: AppModel.scratchAutoCloseKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(scratchAutoClose, forKey: Self.scratchAutoCloseKey) }
    }
    /// After each output round, the `admiral` mod has Sonnet write a PHI-redacted copy of its
    /// structured result, and the SSE feed sends only that copy as the `output` event, tagged
    /// `redacted: true`. The screen, transcript and other events are untouched. Off by default.
    static let redactRepliesKey = "admiral.redactRepliesForSSE"
    static var storedRedactReplies: Bool { UserDefaults.standard.bool(forKey: redactRepliesKey) }
    @Published var redactReplies: Bool = AppModel.storedRedactReplies {
        didSet {
            UserDefaults.standard.set(redactReplies, forKey: Self.redactRepliesKey)
            sessions.syncRedactionFlags()
        }
    }
    /// New tabs start as scratch tabs: the New form's toggle starts here, and an MCP
    /// `commission` that doesn't say `scratch` follows it (Settings → Bridge & API).
    static let scratchByDefaultKey = "admiral.scratchByDefault"
    @Published var scratchByDefault: Bool =
        UserDefaults.standard.bool(forKey: AppModel.scratchByDefaultKey) {
        didSet { UserDefaults.standard.set(scratchByDefault, forKey: Self.scratchByDefaultKey) }
    }

    /// Resolves the launch recipe for a new claude session. A closure, not a value: the
    /// real arm re-reads `LaunchOptionsStore` on every call, so a Settings → Sessions edit
    /// reaches the next commission without a relaunch (test/direct arms return a fixed
    /// recipe).
    private let agentTypeProvider: () -> AgentType
    private var agentType: AgentType { agentTypeProvider() }
    /// Persists Settings → Sessions (managed launch flags). Shared with `SettingsWindow`,
    /// profile-aware like the tab stores.
    let launchOptionsStore: LaunchOptionsStore
    /// Settings → Sessions → bash TUI reopen allowlist.
    let bashRestoreStore: BashRestoreSettingsStore
    /// The CC Switch provider configs on this machine, read fresh whenever a surface that
    /// offers them opens (the New-session form, Settings → Sessions) — CC Switch is a
    /// separate app the user edits while Admiral runs. Empty when it isn't installed, which
    /// is what hides the custom-model control entirely.
    @Published private(set) var ccSwitchProviders: [CCSwitchProvider] = []

    /// Re-read CC Switch's catalog — from the database Settings → Sessions points at (the
    /// standard location unless overridden). Cheap (a read-only SQLite query) and called
    /// from the surfaces that show it, so a provider added next door appears without an
    /// app restart.
    func refreshCCSwitchProviders() {
        ccSwitchProviders = CCSwitchCatalog.load(bookmark: launchOptionsStore.load().ccSwitchBookmark)
    }

    /// The provider a `providerID` names, if it is still in the catalog.
    func ccSwitchProvider(id: String?) -> CCSwitchProvider? {
        guard let id else { return nil }
        return ccSwitchProviders.first { $0.id == id }
    }
    /// Launch recipe for a "New Bash": a plain interactive login `zsh` (no `claude`, no
    /// `--session-id` ⇒ no transcript/hooks). Still gets a persistent id and restores on
    /// relaunch via OpenSessionsStore. Spawned via the manager's `executablePath`
    /// (`/bin/zsh`), so only the args differ from claude.
    private let bashAgentType = AgentType(
        id: "bash", displayName: "Bash", executableName: "zsh",
        defaultArgs: ["-il"], symbolName: "terminal"
    )
    private let testCwds: [String]
    private var testCwdIndex = 0
    private let testTranscript: String?
    /// UI-test seed: pipe-separated goals for the seeded transcript session.
    private let testGoals: String?
    private let testResolveSession: String?
    private let realCommissionCwd: String?
    private let realPrompt: String?
    private let realProof: String?
    /// `-probeLinkWiring <proofPath>`: headless check that a spawned terminal routes link
    /// clicks to our Handle (the -50 fix) — writes PASS/FAIL and exits (see `start()`).
    private let probeLinkWiring: String?
    /// `-probePalette <proofPath>`: headless check that a spawned terminal serves the
    /// standard xterm 256-color cube rather than SwiftTerm's theme-derived `.base16Lab`
    /// palette — writes PASS/FAIL per index and exits (see `start()`).
    private let probePalette: String?
    /// `-probeSurface <proofPath>`: headless check that a spawned terminal's default
    /// background is Admiral's themed surface and not the *system* appearance's — writes
    /// PASS/FAIL and exits (see `start()`).
    private let probeSurface: String?
    /// `-probeFileDrop <proofPath>`: headless check that a spawned terminal takes a Finder file
    /// drop and types the paths as iTerm2 does — writes PASS/FAIL and exits (see `start()`).
    private let probeFileDrop: String?
    /// `-probeChat <cwd> -probeChatProof <file>`: the Chat view against a real claude (see
    /// `ChatProbe.swift`) — writes PASS/FAIL and exits.
    private let probeChat: String?
    private let probeChatProof: String?
    /// `-probeSchedule <cwd> -probeScheduleProof <file>`: scheduled runs against a real claude
    /// (see `ScheduleProbe.swift`) — writes PASS/FAIL and exits.
    private let probeSchedule: String?
    private let probeScheduleProof: String?
    /// `-probeSchedulesUI <dir>`: the Schedules UI (sidebar row + sheet) drawn into PNGs, no
    /// claude (see `ScheduleProbe.swift`) — exits when drawn.
    private let probeSchedulesUI: String?
    /// `-probeTitlebar <proofPath> [-probeTitlebarTranscript <jsonl>]`: the header still drags
    /// the window and its buttons still click (see `TitlebarProbe.swift`) — writes PASS/FAIL and exits.
    private let probeTitlebar: String?
    private let probeTitlebarTranscript: String?
    /// `-probeSheets <dir>`: the Schedules and Settings sheets drawn into PNGs, then closed by
    /// their Close button and by Esc on the real window (see `SheetsProbe.swift`) — writes PASS/FAIL and exits.
    private let probeSheets: String?
    /// `-probeGroupsUI <dir>`: the group chat UI (sidebar, window, picker, popover, sheet) drawn
    /// into PNGs from a fixture, dark and light, no claude (see `GroupsProbe.swift`).
    private let probeGroupsUI: String?
    private var timer: Timer?
    /// Optional isolation profile (from `ADMIRAL_PROFILE` / `-admiralProfile`). When set, the
    /// tab list and per-tab data (open-sessions restore, appearance, footprint) live in a
    /// separate UserDefaults suite, and the bridge socket gets its own path — so a dev/test
    /// instance starts with no tabs and never touches the default instance's tabs. nil = the
    /// normal shared instance, byte-identical to before.
    private let profile: String?
    /// This instance's bridge socket path (profile-aware). Used both to serve the bridge and,
    /// exported as `ADMIRAL_SOCKET`, to point each session's injected relay at the right
    /// instance. Read by Settings → Bridge & API for display.
    let bridgeSocketPath: String
    /// Unix socket API tool tabs park `tools/call` on. Profile-aware, beside the bridge socket.
    let clientToolSocketPath: String
    /// `start()` runs once. The window's `.onAppear` re-fires when the window is closed and
    /// reopened (the app stays alive), and re-running the restore loop would duplicate sessions.
    private var started = false
    private var bag = Set<AnyCancellable>()

    init() {
        let args = ProcessInfo.processInfo.arguments
        func argValue(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        // UI-test injection: a cheap executable + args + a fixed cwd so the commission
        // flow runs without the file picker or a real `claude`.
        let testExe = argValue("-uiTestExecutable")
        let testArgs = argValue("-uiTestArgs").map { $0.components(separatedBy: "|||") } ?? []
        self.testCwds = argValue("-uiTestCwd")?.components(separatedBy: "|||") ?? []
        self.testTranscript = argValue("-uiTestTranscript")
        self.testGoals = argValue("-uiTestGoals")
        self.testResolveSession = argValue("-uiTestResolveSession")
        self.realCommissionCwd = argValue("-realCommission")
        self.realPrompt = argValue("-realPrompt")
        self.realProof = argValue("-realProof")
        self.probeLinkWiring = argValue("-probeLinkWiring")
        self.probePalette = argValue("-probePalette")
        self.probeSurface = argValue("-probeSurface")
        self.probeFileDrop = argValue("-probeFileDrop")
        self.probeChat = argValue("-probeChat")
        self.probeChatProof = argValue("-probeChatProof")
        self.probeSchedule = argValue("-probeSchedule")
        self.probeScheduleProof = argValue("-probeScheduleProof")
        self.probeSchedulesUI = argValue("-probeSchedulesUI")
        self.probeTitlebar = argValue("-probeTitlebar")
        self.probeTitlebarTranscript = argValue("-probeTitlebarTranscript")
        self.probeSheets = argValue("-probeSheets")
        self.probeGroupsUI = argValue("-probeGroupsUI")
        let testHome = argValue("-uiTestClaudeHome").map { URL(fileURLWithPath: $0) }
        // Isolation profile: `ADMIRAL_PROFILE` env (primary — a dev instance is launched by
        // direct-exec with the var set) or `-admiralProfile <slug>`. When set, the tab stores
        // use a dedicated UserDefaults suite so this instance's tab list is independent of the
        // default instance's — it starts empty and its tab changes never touch the other's.
        // (Resolved BEFORE the launch recipe: the recipe reads this suite's launch options.)
        let profile = (ProcessInfo.processInfo.environment["ADMIRAL_PROFILE"].flatMap { $0.isEmpty ? nil : $0 }
            ?? argValue("-admiralProfile"))?
            .trimmingCharacters(in: .whitespaces)
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        self.profile = (profile?.isEmpty ?? true) ? nil : profile
        self.operatorTokenMirror = GuardedOperatorTokenMirror(
            wrapping: KeychainOperatorTokenMirror(profile: self.profile),
            timeout: OperatorTokenStore.steadyTimeout)
        let storeDefaults: UserDefaults = self.profile
            .flatMap { UserDefaults(suiteName: "com.pedro.admiral.\($0)") } ?? .standard
        let launchStore = LaunchOptionsStore(defaults: storeDefaults)
        self.launchOptionsStore = launchStore
        let bashRestoreStore = BashRestoreSettingsStore(defaults: storeDefaults)
        self.bashRestoreStore = bashRestoreStore
        self.watchdogConfigStore = WatchdogConfigStore(defaults: storeDefaults)
        self.watchdogStateStore = WatchdogStateStore(defaults: storeDefaults)
        self.goalsNudgeConfigStore = GoalsNudgeConfigStore(defaults: storeDefaults)
        AdmiralConfigStore.migrateLegacyFile()
        let loadedConfig = AdmiralConfigStore.load()
        self.config = loadedConfig
        // Here, not in `start()`: that runs from the window's onAppear, after the first paint,
        // and views that don't redraw would keep the colors they resolved without the flag.
        Theme.usesStealthPalette = loadedConfig.features.stealthTheme

        let launchExecutable: String
        let agentTypeProvider: () -> AgentType
        if let testExe {
            let testType = AgentType(
                id: "test", displayName: "Test Agent",
                executableName: URL(fileURLWithPath: testExe).lastPathComponent,
                defaultArgs: testArgs, symbolName: "hammer"
            )
            agentTypeProvider = { testType }
            launchExecutable = testExe
        } else if args.contains("-realDirectSpawn") {
            // Control arm: spawn the claude binary directly (no login shell) to prove
            // the login-shell launch is what makes claude persist its transcript.
            agentTypeProvider = { .claudeCode }
            launchExecutable = AppModel.resolveClaude()
        } else {
            // The REAL recipe: claude inside an interactive login zsh — a Finder-launched app
            // inherits no PATH/env, so the login shell is what finds claude and its tools. The
            // zsh wrapper also means closing the PTY tears down the whole process group, so
            // claude doesn't orphan on quit; `resolveClaudePID` upgrades the tracked pid to
            // claude's real one for status. The command line itself is composed by
            // `LaunchOptions` (Settings → Sessions): managed (default) runs `command claude`
            // with app-owned flags — personal shell functions/aliases are skipped, so another
            // machine behaves like this one; unmanaged is the plain `claude` recipe, deferring
            // to the user's shell config. Re-read from the store at EVERY commission so a
            // settings edit reaches the next session. The --session-id placeholder fixes the
            // transcript filename up front; the --name placeholder gives claude the tab's
            // display name (so `claude --resume` / the picker / statusline match Admiral),
            // substituted per session in `commission`. (Team is a bridge/Admiral label — never passed.)
            agentTypeProvider = { .claudeZshRecipe(options: launchStore.load()) }
            launchExecutable = "/bin/zsh"
        }
        self.agentTypeProvider = agentTypeProvider

        let host = SwiftTermHost()
        // claude is launched via an interactive login shell (see launchExecutable),
        // which sources the user's env (PATH etc.) — so no env capture is needed. The
        // app already inherits HOME/USER from launchd, so ~/.claude resolves.
        // Inject the PostToolUse hook + Admiral's own bridge MCP only for the real zsh/claude
        // recipe (not test or direct-spawn arms). nil → SessionManager skips injection.
        let realRecipe = (testExe == nil && !args.contains("-realDirectSpawn"))
        let hookHelper: String? = realRecipe ? AppModel.hookHelperPath() : nil
        let bridgeMCPCommand: String? = realRecipe ? AppModel.bridgeMCPCommand() : nil
        let clientMCPCommand: String? = realRecipe ? AppModel.clientMCPCommand() : nil
        // Per-instance bridge socket: the default path, or a profile-specific one so a dev
        // instance's sessions reach ITS bridge, not the default instance's. Exported into the
        // session env so the injected admiral-bridge-mcp relay connects to the right socket.
        let bridgeSocketPath = self.profile
            .map { AdmiralPaths.defaultSupportDir.appendingPathComponent("bridge-\($0).sock").path }
            ?? BridgeSocketServer.defaultPath
        self.bridgeSocketPath = bridgeSocketPath
        let clientToolSocketPath = self.profile
            .map { AdmiralPaths.defaultSupportDir.appendingPathComponent("client-tools-\($0).sock").path }
            ?? ClientToolSocketServer.defaultPath
        self.clientToolSocketPath = clientToolSocketPath
        var overrides: [String: String] = [:]
        overrides["ADMIRAL_SOCKET"] = bridgeSocketPath

        let manager = SessionManager(
            host: host,
            claudeHome: testHome ?? SessionManager.defaultClaudeHome,
            executablePath: launchExecutable,
            environmentOverrides: overrides,
            // Every commission path (incl. the bridge, which passes no agentType) must
            // use THIS recipe — it matches `launchExecutable` (the zsh wrapper). A provider,
            // so every commission re-reads the launch options.
            defaultAgentTypeProvider: agentTypeProvider,
            // Re-read each sweep; reads UserDefaults directly (init runs before self exists).
            idleReapThresholdProvider: {
                TimeInterval(AppModel.storedScratchTabIdleMinutes * 60)
            },
            appearanceStore: SessionAppearanceStore(defaults: storeDefaults),
            openSessionsStore: OpenSessionsStore(defaults: storeDefaults),
            hookHelper: hookHelper,
            bridgeMCPCommand: bridgeMCPCommand,
            clientMCPCommand: clientMCPCommand,
            clientToolSocketPath: clientToolSocketPath,
            touchedReposStore: TouchedReposStore(defaults: storeDefaults),
            // Re-read per call (like the recipe above), so a provider edited in CC Switch —
            // a rotated token, a fixed base URL — reaches the next reload or restore. The
            // database comes from the same launch options, so the Settings override holds
            // here too.
            providerResolver: { id in
                CCSwitchCatalog.load(bookmark: launchStore.load().ccSwitchBookmark)
                    .first { $0.id == id }
            }
        )
        self.host = host
        self.sessions = manager
        // Re-read per commission, like the launch recipe: a Settings → Sessions change
        // applies to the next tab, and restored tabs launch after this line.
        manager.acceptPeerMessages = { launchStore.load().acceptsPeerMessages }
        // The `admiral` mod goes into every claude tab; the redaction flag follows the setting.
        // Set before restore, which launches the saved tabs.
        manager.modDir = realRecipe ? AppModel.installMod(supportDir: manager.supportDir) : nil
        manager.redactReplies = { AppModel.storedRedactReplies }
        // Re-read per call: restore, reload and fork find an agent edited in Settings since launch.
        let acpAgentStore = AcpAgentStore(defaults: storeDefaults)
        manager.acpAgents = { acpAgentStore.load() }
        // Goals live in the support dir, not defaults: the hook helper reads them too.
        let goals = GoalsStore(base: manager.supportDir)
        self.goalsStore = goals
        let groupStore = GroupStore(base: manager.supportDir)
        // The durable copy of every group conversation, beside claude's own sessions.
        groupStore.transcript = GroupTranscript(dir: manager.claudeHome.appendingPathComponent("groups", isDirectory: true))
        self.groupStore = groupStore
        self.groupService = GroupService(store: groupStore)
        self.sidebarOrderStore = SidebarOrderStore(base: manager.supportDir)
        self.groupSeen = GroupSeenCursor(defaults: storeDefaults)
        let bridge = BridgeCore(manager: manager, goalsStore: goals)
        bridge.scratchByDefault = { UserDefaults.standard.bool(forKey: AppModel.scratchByDefaultKey) }
        self.bridge = bridge
        self.mcp = MCPServer(bridge: bridge)
        // A schedule's custom model resolves against the same CC Switch database as the
        // New-session form (Settings → Sessions can point elsewhere).
        manager.providerCatalog = { CCSwitchCatalog.load(bookmark: launchStore.load().ccSwitchBookmark) }
        let scheduler = SchedulerService(store: ScheduleStore(base: manager.supportDir), backend: manager,
                                         runConfig: TabRun.Config(turnTimeout: 60 * 60),
                                         providers: { [weak manager] in manager?.providerCatalog() ?? [] })
        self.scheduler = scheduler
        bridge.scheduler = scheduler

        // SwiftUI does NOT propagate a nested ObservableObject's changes to observers of
        // the parent, so forward the SessionManager's change notifications. Without this,
        // mutating `sessions` never redraws the views.
        manager.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &bag)
        // Same for goals, which the panel draws from their file: without this a goal changed
        // from the panel's menu, or over the bridge, shows only once something else redraws.
        goals.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &bag)
        bridge.isWatchdogWatching = { [weak self] sid in self?.isWatchdogWatching(sid) ?? false }
        groupStore.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &bag)
        // Any path that picks a tab (a notification click, a new or forked tab, a run opened
        // from Schedules) leaves group view.
        manager.$selectedID
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in self?.selectedGroupID = nil }
            .store(in: &bag)
        wireGroups()
    }

    // MARK: - Selection

    /// Select a terminal: show it in the detail pane (leaving group view, even when it was
    /// already the selected tab).
    func selectTerminal(_ id: UUID) {
        selectedGroupID = nil
        sessions.selectedID = id
    }

    // MARK: - Keyboard-shortcut driven actions

    /// Bumped to ask the sidebar to expand + focus its search field.
    @Published var searchFocusToken = 0
    /// Bumped to ask the sidebar to delete the current selection (with confirmation).
    @Published var deleteRequestToken = 0

    /// Presents the ⌘/ command palette (prompt box + actions + shortcuts).
    @Published var showCommandPalette = false

    /// Presents the Settings window (Governance hooks + policy live here).
    @Published var showSettings = false
    func openSettings() { showSettings = true }

    func openSchedules() {
        refreshCCSwitchProviders()
        showSchedules = true
    }

    /// Run this support folder's schedules here, unless another Admiral already does; the
    /// holder also ends the runs a quit left `running`.
    private func takeSchedules() {
        schedulerLock = SchedulerLock(base: sessions.supportDir)
        if schedulerLock != nil { scheduler.endInterruptedRuns() }
    }

    /// Show what a run did: its tab if still open, else its session reopened (resumed) in a
    /// new tab named after the schedule.
    func openRun(_ run: ScheduleRun, of schedule: Schedule) {
        guard let sid = run.sessionID else { return }
        showSchedules = false
        if let open = sessions.sessions.first(where: { $0.claudeSessionID == sid }) {
            sessions.selectedID = open.id
            return
        }
        let provider = try? CCSwitchCatalog.resolve(schedule.provider, from: sessions.providerCatalog).get()
        let session = sessions.commission(
            callsign: run.callsign ?? schedule.name, cwd: schedule.cwd, sessionID: sid,
            resume: sessions.hasTranscript(sessionID: sid, cwd: schedule.cwd),
            scratch: schedule.scratch, provider: provider ?? nil)
        sessions.selectedID = session.id
    }

    func requestSearchFocus() { sidebarCollapsed = false; searchFocusToken += 1 }
    func requestDeleteSelected() { deleteRequestToken += 1 }

    // Keyboard navigation (⌘↑/⌘↓/⌘1–9, ⇧⌘↑/⇧⌘↓) walks `sidebarItems` — permanent tabs and
    // groups; scratch tabs are click-only by design. See AppModel+Groups.swift.

    /// Fork a specific session (sidebar right-click) into an independent resumed copy.
    func fork(_ id: UUID) { sessions.fork(id) }
    /// Reload a session (sidebar right-click): kill its process tree and relaunch it as the
    /// same resumed session — the per-tab equivalent of an app restart, to bounce a wedged agent.
    func reload(_ id: UUID) { sessions.reload(id) }
    /// Fork the focused terminal (⇧⌘F / palette).
    func forkSelected() {
        guard let id = sessions.selectedID else { return }
        sessions.fork(id)
    }

    /// "New Claude Code": the commission entry point used by the toolbar/empty-state
    /// buttons. In UI-test mode it commissions the injected directory directly; otherwise
    /// it presents the folder form in claude-code mode.
    func requestCommission() {
        newSessionMode = .claudeCode
        if !testCwds.isEmpty {
            let dir = testCwds[min(testCwdIndex, testCwds.count - 1)]
            testCwdIndex += 1
            newSession(cwd: dir)
        } else {
            showNewTerminal = true
        }
    }

    /// App quit: snapshot allowlisted bash TUIs, then kill process groups.
    func prepareToTerminate() {
        stopUserActivityTimer()
        let settings = bashRestoreStore.load()
        sessions.terminateAll(
            bashRestoreEnabled: settings.enabled,
            bashRestoreAllowlist: settings.allowlistSet)
    }

    /// "New Bash": present the same folder form in bash mode, then open a plain `zsh`
    /// login shell in the chosen folder (no `claude`).
    func requestBash() {
        newSessionMode = .bash
        showNewTerminal = true
    }

    func start() {
        guard !started else { return }   // idempotent — see `started`; window reopen re-fires onAppear
        started = true
        // A peer disconnect on a raw socket write (e.g. BridgeSocketServer) raises
        // SIGPIPE by default, which terminates the whole process — killing every
        // live PTY. Ignore it process-wide; writers see EPIPE instead.
        signal(SIGPIPE, SIG_IGN)
        AppState.shared.model = self

        // claude → macOS notifications: post on OSC 9/777, and a click selects the session.
        notifications.onActivate = { [weak self] id in
            self?.sessions.selectedID = id
        }
        // Hook- and tool-driven notifications ride the bridge: `notify` → the one gated post.
        notifications.isViewing = { [weak self] id in
            guard let self else { return false }
            return NSApp.isActive && self.sessions.selectedID == id
        }
        bridge.postNotification = { [weak self] id, kind, title, body in
            self?.notifications.post(kind: kind, title: title, body: body, sessionID: id)
        }
        notifications.start()
        host.onNotification = { [weak self] view, text in
            self?.handleTerminalNotification(view: view, text: text)
        }

        // Terminal colors are baked in per appearance, so the host is told what to theme for
        // here and on every later change. Under `.auto` that includes macOS flipping
        // light/dark underneath us — the KVO fires immediately, which seeds the initial value.
        NSApp.publisher(for: \.effectiveAppearance)
            .sink { [weak self] _ in
                self?.applyTheme()
            }
            .store(in: &bag)

        // Wiring probe: link clicks dispatch via the view's `terminalDelegate`; assert a
        // fresh spawn routes them to our Handle (the -50 fix), not SwiftTerm's default.
        // Fully synchronous, and exits before demo seeds / restore / the bridge socket, so
        // a probe launch never touches a live instance's tabs or steals its socket.
        if let proofPath = probeLinkWiring {
            let handle = host.spawn(
                executable: "/bin/zsh", args: ["-il"],
                env: ["TERM": "xterm-256color", "HOME": NSHomeDirectory()],
                cwd: NSHomeDirectory(), onExit: { _ in }
            )
            let wired = host.view(for: handle)?.terminalDelegate === (handle as AnyObject)
            host.terminate(handle)
            try? "linkWiring: \(wired ? "PASS" : "FAIL")\n"
                .write(toFile: proofPath, atomically: true, encoding: .utf8)
            exit(wired ? 0 : 1)
        }

        // Palette probe: SwiftTerm derives colors 16–255 from the terminal's background
        // unless the strategy is pinned, which washes 256-color TUIs out in dark mode.
        // Assert a fresh spawn serves the standard xterm cube, whatever the theme is.
        if let proofPath = probePalette {
            let handle = host.spawn(
                executable: "/bin/zsh", args: ["-il"],
                env: ["TERM": "xterm-256color", "HOME": NSHomeDirectory()],
                cwd: NSHomeDirectory(), onExit: { _ in }
            )
            // Ask the emulator itself, over OSC 4 — the palette isn't readable in-process,
            // and this exercises the same surface a real TUI would use.
            var reply = ""
            host.captureResponses(handle) { reply += String(decoding: $0, as: UTF8.self) }
            // 214 is the cube's (5,3,0) → #ffaf00; 244 sits on the gray ramp → #808080;
            // 231 is the cube's white corner. All three are LAB-interpolation casualties
            // under SwiftTerm's default strategy.
            let checks: [(Int, String)] = [
                (214, "rgb:ffff/afaf/0000"), (244, "rgb:8080/8080/8080"),
                (231, "rgb:ffff/ffff/ffff"),
            ]
            for (idx, _) in checks {
                host.view(for: handle)?.feed(text: "\u{1b}]4;\(idx);?\u{1b}\\")
            }
            let deadline = Date().addingTimeInterval(2)
            while reply.components(separatedBy: "rgb:").count <= checks.count, Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            host.terminate(handle)
            var lines: [String] = []
            var ok = !reply.isEmpty
            for (idx, want) in checks {
                let hit = reply.contains("4;\(idx);\(want)")
                ok = ok && hit
                lines.append("  [\(idx)] want \(want) \(hit ? "PASS" : "FAIL")")
            }
            lines.append("  raw: \(reply.replacingOccurrences(of: "\u{1b}", with: "\\e"))")
            try? (["palette: \(ok ? "PASS" : "FAIL")"] + lines).joined(separator: "\n").appending("\n")
                .write(toFile: proofPath, atomically: true, encoding: .utf8)
            exit(ok ? 0 : 1)
        }

        // Surface probe: a terminal's default background must be Admiral's themed surface,
        // resolved for the appearance the *app* draws in. Force the split that turned every
        // terminal white — macOS light, Admiral dark — so this fails on any machine if the
        // colors go back to being resolved against the system.
        if let proofPath = probeSurface {
            NSApp.appearance = NSAppearance(named: .aqua)
            Theme.usesStealthPalette = false  // the checks below assume the flag starts off
            host.appearance = Theme.appearance(for: .dark)
            let handle = host.spawn(
                executable: "/bin/zsh", args: ["-il"],
                env: ["TERM": "xterm-256color", "HOME": NSHomeDirectory()],
                cwd: NSHomeDirectory(), onExit: { _ in }
            )
            let view = host.view(for: handle)
            // Faithful to RootView: a dark window on a light system, and layer-backed —
            // since e4f31b0 the view's layer is what paints the default background.
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            if let view {
                window.contentView = view
                window.layoutIfNeeded()
                view.display()
            }
            func emulatorBG() -> String {
                guard let c = view?.getTerminal().backgroundColor else { return "none" }
                return String(format: "#%02X%02X%02X", Int(c.red >> 8), Int(c.green >> 8), Int(c.blue >> 8))
            }
            func layerBG() -> String {
                view?.layer?.backgroundColor
                    .flatMap { $0.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            intent: .defaultIntent, options: nil) }
                    .flatMap { cg -> String? in
                        guard let p = cg.components, p.count >= 3 else { return nil }
                        return String(format: "#%02X%02X%02X", Int(p[0] * 255), Int(p[1] * 255), Int(p[2] * 255))
                    } ?? "none"
            }
            let dark = (emulator: emulatorBG(), layer: layerBG())
            // Then switch the theme on the SAME terminal: a live change has to re-theme the
            // sessions already open, not just the next one spawned.
            host.appearance = Theme.appearance(for: .light)
            let light = (emulator: emulatorBG(), layer: layerBG())
            // The Stealth flag keeps the same NSAppearance, so only the palette re-apply can
            // repaint this terminal. Light has to stay white with the flag on.
            host.appearance = Theme.appearance(for: .dark)
            Theme.usesStealthPalette = true
            host.reapplyColors()
            let stealth = (emulator: emulatorBG(), layer: layerBG())
            host.appearance = Theme.appearance(for: .light)
            let stealthLight = (emulator: emulatorBG(), layer: layerBG())
            host.terminate(handle)

            let wantDark = "#121212", wantLight = "#FFFFFF", wantStealth = "#0D1420"
            let checks: [(String, String, String)] = [
                ("stealth emulator background", wantStealth, stealth.emulator),
                ("stealth layer background", wantStealth, stealth.layer),
                ("flag-on light emulator background", wantLight, stealthLight.emulator),
                ("flag-on light layer background", wantLight, stealthLight.layer),
                ("dark emulator background", wantDark, dark.emulator),
                ("dark layer background", wantDark, dark.layer),
                ("relit emulator background", wantLight, light.emulator),
                ("relit layer background", wantLight, light.layer),
            ]
            let ok = checks.allSatisfy { $0.1 == $0.2 }
            try? (["surface: \(ok ? "PASS" : "FAIL")"] + checks.map {
                "  \($0.0): want \($0.1) got \($0.2) \($0.1 == $0.2 ? "PASS" : "FAIL")"
            }).joined(separator: "\n").appending("\n")
                .write(toFile: proofPath, atomically: true, encoding: .utf8)
            exit(ok ? 0 : 1)
        }

        // File-drop probe: SwiftTerm ignores drags, so a Finder drop onto a session did nothing.
        // Drive a fresh spawn through AppKit's own entry points and read what reaches the PTY:
        // the view is registered (without it AppKit never routes a drag here — silently), a file
        // drag is taken and a text-only one (a sidebar tab mid-reorder) refused, and the drop
        // types iTerm2's escaped paths, bracketed only while the program has asked for that.
        if let proofPath = probeFileDrop {
            // `sleep` writes nothing back, so no output of its own can flip the paste mode.
            let handle = host.spawn(
                executable: "/bin/sleep", args: ["30"],
                env: ["TERM": "xterm-256color", "HOME": NSHomeDirectory()],
                cwd: NSHomeDirectory(), onExit: { _ in }
            )
            let view = host.view(for: handle)
            var typed = ""
            host.captureResponses(handle) { typed += String(decoding: $0, as: UTF8.self) }
            let files = NSPasteboard.withUniqueName(), text = NSPasteboard.withUniqueName()
            files.writeObjects([
                "/Users/me/Library/Mobile Documents/com~apple~CloudDocs/Documents/Reports/0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0-list.pdf",
                "/Users/me/Library/Mobile Documents/com~apple~CloudDocs/Documents/Reports/Quarterly Report - Q3 2026.pdf",
            ].map { NSURL(fileURLWithPath: $0) })
            text.writeObjects([UUID().uuidString as NSString])
            // What Finder offers for a plain (unmodified) file drag.
            let finder: NSDragOperation = [.copy, .link, .generic, .move, .delete]
            func accepted(_ pasteboard: NSPasteboard) -> String {
                let op = view?.draggingEntered(ProbeDrag(pasteboard, offering: finder)) ?? []
                return op == .generic ? "generic" : op.isEmpty ? "refused" : "operation \(op.rawValue)"
            }
            func drop(bracketedPaste: Bool) -> String {
                view?.feed(text: bracketedPaste ? "\u{1b}[?2004h" : "\u{1b}[?2004l")
                typed = ""
                _ = view?.performDragOperation(ProbeDrag(files, offering: finder))
                return typed.replacingOccurrences(of: "\u{1b}", with: "\\e")
            }
            let paths = #"/Users/me/Library/Mobile\ Documents/com\~apple\~CloudDocs/Documents/Reports/0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0-list.pdf /Users/me/Library/Mobile\ Documents/com\~apple\~CloudDocs/Documents/Reports/Quarterly\ Report\ -\ Q3\ 2026.pdf "#
            let checks: [(String, String, String)] = [
                ("registered for file drags", "yes",
                 view?.registeredDraggedTypes.contains(.fileURL) == true ? "yes" : "no"),
                ("file drag", "generic", accepted(files)),
                ("text-only drag", "refused", accepted(text)),
                ("drop, bracketed paste on", #"\e[200~"# + paths + #"\e[201~"#, drop(bracketedPaste: true)),
                ("drop, bracketed paste off", paths, drop(bracketedPaste: false)),
            ]
            host.terminate(handle)
            files.releaseGlobally()
            text.releaseGlobally()
            let ok = checks.allSatisfy { $0.1 == $0.2 }
            try? (["fileDrop: \(ok ? "PASS" : "FAIL")"] + checks.map {
                "  \($0.0): want \($0.1) got \($0.2) \($0.1 == $0.2 ? "PASS" : "FAIL")"
            }).joined(separator: "\n").appending("\n")
                .write(toFile: proofPath, atomically: true, encoding: .utf8)
            exit(ok ? 0 : 1)
        }

        let env = ProcessInfo.processInfo.environment
        if env["ADMIRAL_DEMO"] != nil || env["ADMIRAL_SNAPSHOT"] != nil {
            DemoData.seed(into: sessions)
        }
        // UI-test seed: render a session from a transcript already on disk (proves the
        // parser/render path independent of spawning).
        if let tpath = testTranscript {
            var session = AgentSession(callsign: "real-session", cwd: "/tmp",
                                       claudeSessionID: "uitest-sid",
                                       transcriptPath: tpath, status: .idle)
            sessions.register(session, handle: nil)
            sessions.selectedID = session.id
            sessions.refreshConversation(session.id)
            // Goals for the same seeded session, pipe-separated, so the panel's Goals
            // section can be driven without a live peer setting them over the bridge.
            // A leading "+" seeds the goal as already met (the struck-through row).
            if let spec = testGoals {
                let raw = spec.components(separatedBy: "|")
                if case var .success(seeded) = SessionGoals.make(from: raw.map {
                    $0.hasPrefix("+") ? String($0.dropFirst()) : $0
                }) {
                    let done = zip(seeded.goals, raw).filter { $1.hasPrefix("+") }.map(\.0.id)
                    seeded.apply(statuses: Dictionary(uniqueKeysWithValues: done.map { ($0, GoalStatus.met) }))
                    goalsStore.set(seeded, forSession: "uitest-sid")
                }
            }
            _ = session
        }

        // UI validation gate: render the composed UI to a PNG and quit. AFTER the seeds
        // above, so a snapshot can be driven from a seeded transcript/goals rather than
        // only from DemoData.
        if let snapshotPath = env["ADMIRAL_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                SnapshotRenderer.render(model: self, to: snapshotPath)
                NSApp.terminate(nil)
            }
            return
        }
        // Titlebar probe: after the demo seed (so a tab is selected), before restore / the
        // bridge socket, so a probe launch never touches a live instance.
        if let proofPath = probeTitlebar {
            runTitlebarProbe(proof: proofPath, transcript: probeTitlebarTranscript)
            return
        }
        // Sheets probe: same place, for the same reason — and with no scheduler lock taken, its
        // seeded schedules never fire.
        if let dir = probeSheets {
            runSheetsProbe(dir: dir)
            return
        }
        // Groups UI probe: same place — fixture tabs with no process, no bridge, no restore.
        if let dir = probeGroupsUI {
            runGroupsUIProbe(dir: dir)
            return
        }

        // UI-test seed: resolve a transcript through the real pid→session-file→encoded-cwd
        // chain (proves underscore-cwd resolution + render through the UI).
        if let spec = testResolveSession {
            let parts = spec.components(separatedBy: "|")
            if parts.count == 2, let pid = Int32(parts[0]) {
                let cwd = parts[1]
                var session = AgentSession(
                    callsign: (cwd as NSString).lastPathComponent, cwd: cwd, claudePID: pid, status: .idle
                )
                sessions.register(session, handle: nil)
                sessions.selectedID = session.id
                sessions.resolveTranscript(for: session.id)
                _ = session
            }
        }

        // End-to-end proof of the PATH fix: from a Finder launch (minimal PATH),
        // commission a REAL claude, send a prompt, then dump live evidence.
        if let cwd = probeSchedule, let proof = probeScheduleProof {
            // The runs' sessions need the bridge (set_structured_output lives there); only a
            // profiled instance may serve it.
            if profile != nil { startBridgeSocket() }
            takeSchedules()
            runScheduleProbe(cwd: cwd, proof: proof)
        }
        if let dir = probeSchedulesUI { runSchedulesUIProbe(dir: dir) }
        if let cwd = probeChat, let proof = probeChatProof {
            // The probe's session needs the bridge (the AskUserQuestion mirror lives there);
            // only a profiled instance may serve it, never the default instance's socket.
            if profile != nil { startBridgeSocket() }
            runChatProbe(cwd: cwd, proof: proof)
        }
        if let cwd = realCommissionCwd {
            newSession(cwd: cwd)
            if let prompt = realPrompt {
                // Send a few times so it lands once claude's TUI is ready.
                for delay in [10.0, 18.0, 26.0] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        if let id = self?.sessions.selectedID { self?.sessions.send(id, text: prompt) }
                    }
                }
            }
        }
        if let proof = realProof {
            let delay = realCommissionCwd != nil ? 50.0 : 8.0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.dumpRealProof(to: proof)
                NSApp.terminate(nil)
            }
        }

        // Restore the sessions that were open last time, resuming each conversation
        // (claude --resume). Skipped in demo / UI-test seed modes and when a proof is
        // commissioning its own session; a proof-only launch DOES restore (so it's
        // verifiable).
        let isPlainLaunch = testCwds.isEmpty && testTranscript == nil && testResolveSession == nil
            && realCommissionCwd == nil && probeChat == nil && probeSchedule == nil && probeSchedulesUI == nil
            && env["ADMIRAL_DEMO"] == nil
        if isPlainLaunch {
            // Read the catalog before restoring: a tab saved on a provider has to find it
            // again here, or it comes back on Anthropic without saying so.
            refreshCCSwitchProviders()
            // Before restore: a restored ACP tab is offered the bridge only if it is up when
            // the tab launches (the offer rides on session/new|resume|load).
            startSessionBridgeTracking()
            for record in sessions.restorableSessions() {
                // Core decides (and tests) what each record becomes: an ACP tab on its agent —
                // decided before the folder check, since its cwd is the agent's, not this Mac's —
                // a PTY tab, or nothing.
                let canResume: Bool
                switch sessions.restorePlan(for: record) {
                case let .skip(reason):
                    NSLog("Admiral restore: skipping %@: %@", record.callsign, reason)
                    continue
                case let .acp(agent, acpSessionID):
                    sessions.restoreACP(record, agent: agent, acpSessionID: acpSessionID)
                    continue
                case let .pty(resume):
                    canResume = resume
                }
                // Bash tabs reopen as zsh; Claude tabs --resume when a transcript exists
                // (empty Claude sessions recreate at the SAME id so they reopen cleanly).
                let recipe: AgentType = record.isBash ? bashAgentType : agentType
                let session = sessions.commission(
                    callsign: record.callsign, cwd: record.cwd, agentType: recipe,
                    sessionID: record.sessionID, resume: canResume, teamName: record.teamName,
                    provider: record.isBash ? nil
                        : record.providerID.flatMap { id in ccSwitchProviders.first { $0.id == id } }
                )
                // Bash: re-run an allowlisted TUI (basename only) once the login shell is up.
                if record.isBash,
                   let cmd = record.restoreCommand?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !cmd.isEmpty {
                    let id = session.id
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                        _ = self?.sessions.inject(id, text: cmd)
                    }
                }
            }
            // Serve the bridge tools over a loopback socket so bridge_mcp (running inside
            // an Admiral-hosted claude) can drive this app's sessions.
            // Serve on this instance's socket (profile-aware) — the same path exported to
            // sessions as ADMIRAL_SOCKET, so a profiled instance never steals the default one's.
            startBridgeSocket()
            takeSchedules()

            // Anthropic-compatible API: restore the toggle across relaunch when the
            // feature flag is on. apiServer=false never auto-starts, even if UserDefaults says so.
            if config.features.apiServer,
               UserDefaults.standard.bool(forKey: Self.apiServerEnabledKey) {
                startAPIServer()
            }
            // Operator MCP shares the API server (:4141 POST /mcp). Resolve the Keychain token and
            // migrate any legacy token file in the background (never blocks launch).
            recheckOperatorToken()
            // Keep-awake preference: re-acquire the display-sleep assertion if last left on.
            restoreKeepAwakeIfNeeded()
        }

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }

        // Forward watchdog state changes so sidebar rows (which observe AppModel) re-render
        // the badge without their own subscription.
        watchdog.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &bag)
        goalsNudge.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &bag)
    }

    /// Writes end-to-end proof of a real claude session: the live terminal buffer,
    /// the parsed conversation, child-process liveness, and a render of the real
    /// Transcript view.
    private func dumpRealProof(to dir: String) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard let session = sessions.selectedSession else {
            try? "NO SESSION".write(toFile: dir + "/status.txt", atomically: true, encoding: .utf8)
            return
        }
        sessions.refreshConversation(session.id)
        let convo = sessions.conversations[session.id] ?? .empty

        var termText = "(no live handle)"
        if let handle = sessions.handle(for: session.id), let view = host.view(for: handle) {
            let terminal = view.getTerminal()
            var lines: [String] = []
            var row = 0
            while row < 200, let line = terminal.getLine(row: row) {
                lines.append(line.translateToString(trimRight: true))
                row += 1
            }
            termText = lines.joined(separator: "\n")
        }
        try? termText.write(toFile: dir + "/terminal.txt", atomically: true, encoding: .utf8)

        // Diagnostic: exactly what the resolver sees from inside the running app.
        let dbgHome = sessions.claudeHome
        let dbgCwd = session.cwd
        let dbgEncoded = dbgHome.appendingPathComponent("projects")
            .appendingPathComponent(TranscriptLocator.encodeProjectDir(dbgCwd))
        let dbgExists = fm.fileExists(atPath: dbgEncoded.path)
        let dbgCount = (try? fm.contentsOfDirectory(atPath: dbgEncoded.path))?
            .filter { $0.hasSuffix(".jsonl") }.count ?? -1
        let dbgResolve = TranscriptLocator.resolve(
            pid: session.claudePID ?? -1, fallbackCwd: dbgCwd, claudeHome: dbgHome
        )
        let resolveDebug = """
        claudeHome=\(dbgHome.path)
        cwd=\(dbgCwd)
        encodedDir=\(dbgEncoded.path)
        encodedDirExists=\(dbgExists)
        jsonlCountInDir=\(dbgCount)
        resolve(pid=\(session.claudePID ?? -1)).path=\(dbgResolve.path ?? "nil")
        resolve.sessionId=\(dbgResolve.file?.sessionId ?? "nil")
        NSHomeDirectory=\(NSHomeDirectory())
        """
        try? resolveDebug.write(toFile: dir + "/resolve-debug.txt", atomically: true, encoding: .utf8)

        let alive = session.claudePID.map { kill($0, 0) == 0 } ?? false
        let status = """
        childPid=\(session.claudePID ?? -1)
        childProcessAlive=\(alive)
        claudeSessionId=\(session.claudeSessionID ?? "nil")
        transcriptPath=\(session.transcriptPath ?? "nil")
        conversationTurns=\(convo.turns.count)
        title=\(convo.title ?? "nil")
        """
        try? status.write(toFile: dir + "/status.txt", atomically: true, encoding: .utf8)

        // pid isolation: spawn pid → claude's REAL pid (descendant walk) → session file.
        let spawnPid = sessions.handle(for: session.id)?.pid ?? (session.claudePID ?? -1)
        let snap = ProcessTree.snapshot()
        let realClaude = ProcessTree.findClaudePid(spawnPid: spawnPid, snapshot: snap)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var children: [Int32: [Int32]] = [:]
        for (pid, value) in snap { children[value.ppid, default: []].append(pid) }
        var treeLines: [String] = []
        var stack = [spawnPid]
        var seen = Set<Int32>()
        while let pid = stack.popLast() {
            if seen.contains(pid) { continue }
            seen.insert(pid)
            if let entry = snap[pid] {
                treeLines.append("  pid=\(pid) :: \(entry.command.prefix(64))")
                stack.append(contentsOf: children[pid] ?? [])
            }
        }
        let realSessionFileExists = realClaude
            .map { fm.fileExists(atPath: "\(home)/.claude/sessions/\($0).json") } ?? false
        let iso = """
        spawnPid=\(spawnPid)
        realClaudePid=\(realClaude.map(String.init) ?? "NONE")
        sessions/<realClaudePid>.json EXISTS = \(realSessionFileExists)
        --- descendant tree of spawnPid ---
        \(treeLines.joined(separator: "\n"))
        """
        try? iso.write(toFile: dir + "/pidisolation.txt", atomically: true, encoding: .utf8)

        let turns = convo.turns.map { turn -> String in
            switch turn {
            case let .user(_, text): return "USER: \(text.prefix(240))"
            case let .assistant(_, md, _): return "ASSISTANT: \(md.prefix(240))"
            case let .thinking(_, text): return "THINKING: \(text.prefix(80))"
            case let .tool(_, name, params, _, state): return "TOOL[\(state)]: \(name) \(params.prefix(80))"
            }
        }.joined(separator: "\n")
        try? turns.write(toFile: dir + "/conversation.txt", atomically: true, encoding: .utf8)

        let content = TranscriptContent(conversation: convo)
            .frame(width: 880)
            .padding(20)
            .background(Theme.contentBackground)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: dir + "/transcript.png"))
        }
    }

    /// Commission a new claude session in `cwd` (callsign defaults to the folder name, no
    /// team). Used by the UI-test and real-commission paths.
    func newSession(cwd: String) {
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        let session = sessions.commission(callsign: name.isEmpty ? "session" : name, cwd: cwd, agentType: agentType)
        _ = session
    }

    /// Commission from the New… form: explicit name and folder. The active
    /// `newSessionMode` picks the recipe — a `claude` session ("New Claude Code") or a
    /// plain `zsh` login shell ("New Bash").
    func newSession(name: String, cwd: String, provider: CCSwitchProvider? = nil, scratch: Bool = false) {
        let agentName = name.trimmingCharacters(in: .whitespaces)
        let isBash = newSessionMode == .bash
        let session = sessions.commission(
            callsign: agentName.isEmpty ? (isBash ? "bash" : "session") : agentName,
            cwd: cwd,
            agentType: isBash ? bashAgentType : agentType,
            scratch: scratch,
            // A plain shell has no `--settings` file to carry one, so the form offers the
            // box only for a claude session.
            provider: isBash ? nil : provider
        )
        // The user named this session explicitly — lock it as the custom name so claude's
        // AI-generated transcript title can't overwrite it (and it persists across relaunch).
        if !agentName.isEmpty { sessions.rename(session.id, to: agentName) }
        // commission leaves a scratch tab unselected (API tabs mustn't steal focus); this one
        // the user just asked for.
        if scratch { selectTerminal(session.id) }
    }

    /// Post a macOS notification for a claude OSC notification from `view`'s session
    /// (titled with the session name; a click selects it). Skipped for the terminal you're
    /// already looking at.
    private func handleTerminalNotification(view: LocalProcessTerminalView, text: String) {
        guard let session = sessions.sessions.first(where: {
            host.view(for: sessions.handle(for: $0.id)) === view
        }) else { return }
        // Settings → Notifications and the "already looking at it" rule live in the service.
        notifications.post(kind: .terminal, title: session.displayTitle, body: text, sessionID: session.id)
    }

    /// Keep the session bridge listener in step with the configured ACP agents — up while
    /// there is at least one, down when there are none — now and on every defaults change
    /// (Settings → Agents saves there). A tab is offered the bridge only if it is up when the
    /// tab launches; `sessionBridgeRunning` is how `commissionACP` asks.
    private func startSessionBridgeTracking() {
        sessions.sessionBridgeRunning = { [weak self] in self?.sessionBridgeServer != nil }
        syncSessionBridge()
        guard acpAgentsObserver == nil else { return }
        acpAgentsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncSessionBridge() }
        }
    }

    private func syncSessionBridge() {
        let wanted = !sessions.acpAgents().isEmpty
        if wanted, sessionBridgeServer == nil {
            let endpoint = SessionMCPEndpoint(mcp: mcp, tokenIsLive: { [weak manager = sessions] in
                manager?.acpTokenIsLive($0) ?? false
            })
            let server = SessionMCPHTTPServer(endpoint: endpoint)
            guard server.start() != nil else {
                // Retried on the next defaults change; until then ACP tabs launch without it.
                NSLog("Admiral: session bridge could not bind 127.0.0.1:%d", Int(SessionMCPHTTPServer.defaultPort))
                return
            }
            sessionBridgeServer = server
        } else if !wanted, let server = sessionBridgeServer {
            server.stop()
            sessionBridgeServer = nil
        }
    }

    /// Serve the bridge tools over this instance's loopback socket (profile-aware — the same
    /// path exported to sessions as ADMIRAL_SOCKET, so a profiled instance never steals the
    /// default one's) so the bridge relay inside an Admiral-hosted claude can drive this app.
    private func startBridgeSocket() {
        guard bridgeSocket == nil else { return }
        let server = BridgeSocketServer(mcp: mcp, path: bridgeSocketPath)
        server.start()
        bridgeSocket = server
        // The client-tool broker is a different socket on purpose: a park must not occupy
        // a bridge connection slot, and it must not hop to the main actor to wait.
        let client = ClientToolSocketServer(path: clientToolSocketPath, broker: sessions.clientToolBroker)
        client.start()
        clientToolSocket = client
    }

    // MARK: - Chat view

    /// Per-session view mode, read from the file the hook also reads (`ChatLedger.mode`) and
    /// cached so a render never touches disk. Keyed by claude session id.
    private var viewModeCache: [String: ChatLedger.Mode] = [:]

    /// Chat or Terminal for `session`. Unmanaged (bash) tabs have no chat: always Terminal.
    /// When `config.features.chatView` is off, every session is forced to Terminal.
    func viewMode(for session: AgentSession) -> ChatLedger.Mode {
        guard config.features.chatView else { return .terminal }
        guard session.agentType.isManaged, let sid = session.claudeSessionID else { return .terminal }
        if let cached = viewModeCache[sid] { return cached }
        let mode = ChatLedger.mode(base: sessions.supportDir, session: sid)
        viewModeCache[sid] = mode
        return mode
    }

    var selectedViewMode: ChatLedger.Mode {
        sessions.selectedSession.map(viewMode(for:)) ?? .terminal
    }

    var selectedHasChat: Bool {
        sessions.selectedSession.map { $0.agentType.isManaged && $0.claudeSessionID != nil } ?? false
    }

    /// ⌘J / the toolbar switch. Written through to the file, so the next AskUserQuestion
    /// the session makes is routed by the mode it is in now.
    /// No-op when `config.features.chatView` is off (chat stays unavailable).
    func setViewMode(_ mode: ChatLedger.Mode, for session: AgentSession) {
        guard config.features.chatView else { return }
        guard session.agentType.isManaged, let sid = session.claudeSessionID else { return }
        ChatLedger.setMode(mode, base: sessions.supportDir, session: sid)
        objectWillChange.send()
        viewModeCache[sid] = mode
    }

    func toggleViewMode() {
        guard let session = sessions.selectedSession, selectedHasChat else { return }
        setViewMode(viewMode(for: session) == .chat ? .terminal : .chat, for: session)
    }

    /// The composer's send: the text plus any attached paths (escaped as a Finder drop types
    /// them), typed into the session.
    func sendChat(_ text: String, attachments: [String], to session: AgentSession) {
        var message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let paths = TerminalDrop.pasteText(paths: attachments) {
            message += (message.isEmpty ? "" : " ") + paths.trimmingCharacters(in: .whitespaces)
        }
        guard !message.isEmpty else { return }
        sessions.sendTyped(session.id, text: message)
    }

    /// The question card's Submit: the answers go in as the next prompt.
    func answerAsk(_ questions: [AskQuestion], answers: [String], for session: AgentSession) {
        sessions.answerAsk(session.id, questions: questions, answers: answers)
    }

    func interrupt(_ session: AgentSession) { sessions.interrupt(session.id) }

    /// A file path clicked in the chat. `#L52` (the line the message named) is honoured by
    /// asking VS Code to open there; without a line, or without VS Code, the file opens in
    /// whatever app owns it — the same end as clicking a link in the terminal.
    func openChatFile(_ url: URL) {
        let line = url.fragment.flatMap { $0.hasPrefix("L") ? Int($0.dropFirst()) : nil }
        let file = URL(fileURLWithPath: url.path)
        let link = TerminalLink.forFile(file)
        guard case .file = link else { return link.perform() }   // runnable → Finder, never run
        if let line, let editor = URL(string: "vscode://file\(file.path):\(line)"),
           NSWorkspace.shared.urlForApplication(toOpen: editor) != nil {
            NSWorkspace.shared.open(editor)
            return
        }
        link.perform()
    }

    /// A permission prompt answered from the chat (on a PTY tab, Enter takes claude's "Yes").
    func allowPermission(_ session: AgentSession) {
        sessions.allowPermission(session.id)
    }

    private func tick() {
        sessions.refreshStatuses()
        if scratchAutoClose { sessions.reapIdleScratchTabs() }
        watchdog.tick()
        // After the watchdog: it may have just injected, which wakes the shared idle clock
        // and defers this nudge a cycle — one nudge per session per tick.
        goalsNudge.tick()
        prWatch.tick()
        autoIcon.tick()
        if schedulerLock != nil { scheduler.tick() }
        // Busy group members that went idle get the wake they were holding.
        if groupsEnabled {
            // Woken members that ended their turn without group_say: post the reply for them.
            groupService.postFinishedTurns()
            groupService.flushPending()
            // Names for the prompt hook; skips the write when nothing changed.
            groupService.writeCallsigns()
        }
        // Resolve every session each tick; resolveTranscript's own guard decides whether
        // there's work (not yet found, or a fallback that should upgrade to the exact
        // <session-id> transcript once claude writes it). resolveClaudePID upgrades the
        // tracked pid from the login shell to claude's real child pid (once, then caches).
        for session in sessions.sessions {
            sessions.resolveClaudePID(for: session.id)
            sessions.resolveTranscript(for: session.id)
        }
        if let id = sessions.selectedID { sessions.refreshConversation(id) }
        if let id = sessions.selectedID {
            sessions.refreshChat(id)
            sessions.refreshGitBranch(for: id)       // branch can change mid-session (e.g. a new PR branch)
            sessions.backfillTouchedRepos(for: id)   // one-time seed from the existing transcript
            sessions.refreshTouchedRepos(for: id)
        }
        // A group's Footprint shows its members' repos, tickets and checklists: keep those
        // current while the panel is open (the selected tab is already done above).
        if showTouchedReposPanel, selectedGroup != nil {
            for session in footprintSessions where session.id != sessions.selectedID {
                sessions.refreshConversation(session.id)
                sessions.refreshGitBranch(for: session.id)
                sessions.backfillTouchedRepos(for: session.id)
                sessions.refreshTouchedRepos(for: session.id)
            }
        }
        // Bottom-bar PR first so it reserves its rate-limit slot ahead of the (optional,
        // panel-gated) footprint fetches — it's the status the user is most likely watching.
        refreshPRStatusIfNeeded()
        refreshTouchedReposPRIfNeeded()
        refreshTicketsIfNeeded()
        reindexSpotlight()
    }

    /// Fetch the selected session's PR status off-main — on selection change or every 30s.
    private func refreshPRStatusIfNeeded() {
        guard let id = sessions.selectedID,
              let session = sessions.sessions.first(where: { $0.id == id }) else {
            if prStatus != nil || prSession != nil { prStatus = nil; prSession = nil }
            return
        }
        if prSession != id { prStatus = nil; prSession = id; prBranch = nil; lastPRFetch = .distantPast }
        let branch = session.gitBranch ?? ""
        guard !branch.isEmpty else { if prStatus != nil { prStatus = nil }; return }
        // Branch changed under the same session (e.g. the agent cut a PR branch) → drop the
        // stale chip and refetch now instead of waiting out the 30s throttle.
        if prBranch != branch { prBranch = branch; prStatus = nil; lastPRFetch = .distantPast }
        guard !prFetchInFlight, Date().timeIntervalSince(lastPRFetch) > 30 else { return }
        guard let gh = github(for: session) else { if prStatus != nil { prStatus = nil }; return }
        prFetchInFlight = true
        lastPRFetch = Date()
        let cwd = session.cwd
        Task.detached {
            let status = await gh.prStatus(branch: branch, cwd: cwd)
            await MainActor.run {
                self.prFetchInFlight = false
                guard self.sessions.selectedID == id else { return }
                self.prStatus = status
            }
        }
    }

    /// Drives the merge-confirm popover (anchored on the StatusBar chip). Set by the chip
    /// click and the ⇧⌘M command so both go through the same confirmation.
    @Published var confirmingMerge = false

    /// Ask to merge the selected PR — shows the confirm popover when it's actually
    /// mergeable (a no-op otherwise, so the menu item / shortcut can be a safe stray press).
    func requestMergeSelectedPR() {
        guard prStatus?.canMerge == true, prStatus?.isMerged == false else { return }
        confirmingMerge = true
    }

    /// Open the selected session's PR in the browser.
    func openSelectedPR() {
        guard let pr = prStatus, let url = URL(string: pr.url) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Merge the selected session's PR (repo's preferred method), then force a refresh.
    func mergeSelectedPR() {
        guard let pr = prStatus, pr.canMerge, !pr.isMerged, let id = sessions.selectedID,
              let session = sessions.sessions.first(where: { $0.id == id }) else { return }
        guard let gh = github(for: session) else { return }
        let cwd = session.cwd, number = pr.number
        Task.detached {
            let error = await gh.merge(number: number, cwd: cwd)
            await MainActor.run {
                self.lastPRFetch = .distantPast  // re-fetch to reflect MERGED (or surface error)
                if let error { print("Admiral: gh merge #\(number) failed: \(error)") }
            }
        }
    }

    /// Enrich the selected session's touched repos with PR status — only while the panel is
    /// open, per-repo throttled to 30s, one fetch in flight per repo. A repo can span several
    /// branches; fetch each branch's PR and keep the distinct set (one chip-group per PR).
    /// Skips repos with no branch.
    /// For a group, a repo several members touched is fetched once, over the union of their
    /// branches (`GroupFootprint.merge`, keyed by tab id), and the result lands on every one
    /// of them — so the shared throttle per root never sees two branch sets fighting.
    private func refreshTouchedReposPRIfNeeded() {
        guard showTouchedReposPanel else { return }
        let owners = footprintSessions
        guard !owners.isEmpty else { return }
        let rows = GroupFootprint.merge(owners.map {
            GroupFootprint.Member(key: $0.id, repos: $0.touchedRepos, tickets: [])
        }).repos
        for row in rows {
            let repo = row.repo, ids = row.members
            let branches = repo.branches.filter { !$0.isEmpty }
            guard !branches.isEmpty else { continue }
            let root = repo.root
            // The branch set changed (e.g. a new PR branch was added) → drop the throttle so the
            // new PR surfaces now instead of waiting out the 30s window.
            let signature = branches.joined(separator: "\n")
            if touchedPRBranch[root] != signature { touchedPRBranch[root] = signature; touchedPRFetch[root] = .distantPast }
            guard !touchedPRInFlight.contains(root),
                  Date().timeIntervalSince(touchedPRFetch[root] ?? .distantPast) > 30 else { continue }
            touchedPRInFlight.insert(root)
            touchedPRFetch[root] = Date()
            let gh = github
            Task.detached {
                var prs: [PRStatus] = []
                var seen = Set<Int>()
                for branch in branches {
                    guard let pr = await gh.prStatus(branch: branch, cwd: root), !seen.contains(pr.number) else { continue }
                    seen.insert(pr.number)
                    prs.append(pr)
                }
                await MainActor.run {
                    self.touchedPRInFlight.remove(root)
                    for id in ids { self.sessions.setTouchedRepoPRs(id, root: root, prs: prs) }
                }
            }
        }
    }

    /// Merge a touched repo's PR (repo's preferred method), then force a re-fetch of its status.
    func mergeTouchedRepoPR(root: String, number: Int) {
        let gh = github
        Task.detached {
            let error = await gh.merge(number: number, cwd: root)
            await MainActor.run {
                self.touchedPRFetch[root] = .distantPast
                if let error { print("Admiral: gh merge #\(number) in \(root) failed: \(error)") }
            }
        }
    }

    // MARK: - Tickets

    /// Scan the selected session's chat ledger for ticket keys — only while the Footprint
    /// panel is open, and only when the ledger (or the patterns) changed. Then enrich with
    /// status if Jira is connected.
    /// For a group, every member's ledger is scanned, and their keys are enriched in one batch.
    private func refreshTicketsIfNeeded() {
        guard showTouchedReposPanel else { return }
        let owners = footprintSessions
        for session in owners { scanTickets(of: session) }
        var keys: [String] = []
        for key in owners.flatMap({ $0.tickets.map(\.key) }) where !keys.contains(key) { keys.append(key) }
        if !owners.isEmpty { refreshTicketStatusesIfNeeded(keys: keys) }
    }

    private func scanTickets(of session: AgentSession) {
        guard let sid = session.claudeSessionID else { return }
        let id = session.id
        let base = sessions.supportDir
        let path = ChatLedger.url(base: base, session: sid).path
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let patterns = config.tickets.patterns
        let signature = "\(size)|\(mtime)|\(patterns.joined(separator: "\u{1f}"))"
        if ticketScanSignature[id] != signature, !ticketScanInFlight.contains(id) {
            ticketScanInFlight.insert(id)
            Task.detached(priority: .utility) {
                let text = TicketKeyFinder.scanText(of: ChatLedger.read(base: base, session: sid, tail: nil))
                let keys = TicketKeyFinder.findKeys(in: text, patterns: patterns)
                await MainActor.run {
                    self.ticketScanInFlight.remove(id)
                    self.ticketScanSignature[id] = signature
                    self.sessions.setTickets(id, keys.map(self.ticketRef(for:)))
                }
            }
        }
    }

    /// The row for `key`: cached status only while connected, else the bare key.
    private func ticketRef(for key: String) -> TicketRef {
        guard ticketsConnected, let cached = ticketStatusCache[key] else { return TicketRef(key: key) }
        return cached
    }

    /// Re-derive every session's ticket rows from the status cache (after a fetch, a
    /// connect, or a disconnect).
    private func reapplyTicketStatuses() {
        for session in sessions.sessions where !session.tickets.isEmpty {
            sessions.setTickets(session.id, session.tickets.map { ticketRef(for: $0.key) })
        }
    }

    /// Fetch status for keys not fetched in the last 30s, one batch in flight. A failed
    /// fetch leaves the key without (new) status; the row still shows.
    private func refreshTicketStatusesIfNeeded(keys: [String]) {
        guard ticketsConnected, !ticketStatusInFlight else { return }
        let clientId = config.tickets.jira.clientId
        guard !clientId.isEmpty else { return }
        let now = Date()
        let due = keys.filter { now.timeIntervalSince(ticketStatusFetch[$0] ?? .distantPast) > 30 }
        guard !due.isEmpty else { return }
        ticketStatusInFlight = true
        for key in due { ticketStatusFetch[key] = now }
        Task.detached(priority: .utility) {
            var results: [String: TicketRef] = [:]
            var stillConnected = true
            do {
                let tokens = try await JiraOAuth.validTokens(clientId: clientId)
                for key in due {
                    if let ref = await JiraTicketsClient.fetchIssue(key: key, tokens: tokens) { results[key] = ref }
                }
            } catch JiraOAuth.OAuthError.notConnected {
                stillConnected = false
            } catch {
                print("Admiral: Jira token refresh failed: \(error.localizedDescription)")
            }
            await MainActor.run {
                self.ticketStatusInFlight = false
                if !stillConnected { self.ticketsConnected = false }
                self.ticketStatusCache.merge(results) { $1 }
                self.reapplyTicketStatuses()
            }
        }
    }

    /// Open a ticket in the browser via `tickets.openURLTemplate` (or the Jira site).
    func openTicket(_ key: String) {
        guard let url = config.tickets.openURL(for: key) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Persist Settings → Tickets. Re-reads the file first so only `tickets` changes, then
    /// forces a rescan so new patterns apply on the next tick.
    func updateTicketsConfig(_ tickets: AdmiralConfig.TicketsConfig) {
        AdmiralConfigStore.update { $0.tickets = tickets }
        config.tickets = tickets
        ticketScanSignature = [:]
    }

    /// Settings → Experimental Features. Saved to the same config file the flags are read
    /// from, and applied live: the chat view and the API server both read `config.features`
    /// where they are used, so only the running server needs stopping or starting here.
    func updateFeatures(_ features: AdmiralConfig.Features) {
        let before = config.features
        AdmiralConfigStore.update { $0.features = features }
        config.features = features
        if before.apiServer, !features.apiServer {
            stopAPIServer()
        } else if !before.apiServer, features.apiServer,
                  UserDefaults.standard.bool(forKey: Self.apiServerEnabledKey) {
            startAPIServer()
        }
        applyGroupsFlag()
        applyTheme()
    }

    /// Store (or clear, when empty) the Jira OAuth client secret — Keychain only.
    func setJiraClientSecret(_ secret: String) {
        TicketsAuthStore.setClientSecret(secret)
        jiraHasClientSecret = TicketsAuthStore.clientSecret != nil
    }

    /// Sign in to Jira: Atlassian consent in an `ASWebAuthenticationSession`, then code →
    /// tokens (Keychain) → cloudId.
    func connectJira() {
        let jira = config.tickets.jira
        guard !jira.clientId.isEmpty else { jiraAuthError = "Set the OAuth Client ID first."; return }
        guard jiraHasClientSecret else { jiraAuthError = "Set the OAuth client secret first."; return }
        jiraAuth?.cancel()
        jiraAuthError = nil
        jiraConnecting = true
        let auth = JiraAuthSession()
        jiraAuth = auth
        let started = auth.start(clientId: jira.clientId) { [weak self] result in
            guard let self, self.jiraAuth === auth else { return }
            switch result {
            case .success(let url): self.completeJiraAuth(callbackURL: url)
            case .failure(let error):
                self.jiraConnecting = false
                self.jiraAuth = nil
                if (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin {
                    self.jiraAuthError = error.localizedDescription
                }
            }
        }
        if !started { jiraConnecting = false; jiraAuth = nil; jiraAuthError = "Could not start the sign-in window." }
    }

    /// `admiral://oauth/jira?...` — from the auth session, or delivered by LaunchServices.
    func handleOpenURL(_ url: URL) {
        guard url.scheme == "admiral", url.host == "oauth", url.path == "/jira", jiraAuth != nil else { return }
        completeJiraAuth(callbackURL: url)
    }

    private func completeJiraAuth(callbackURL: URL) {
        guard let auth = jiraAuth else { return }
        jiraAuth = nil
        let jira = config.tickets.jira
        let pkce = auth.pkce
        Task {
            do {
                try await JiraOAuth.complete(callbackURL: callbackURL, clientId: jira.clientId,
                                             siteURL: jira.siteURL, pkce: pkce)
                self.ticketsConnected = TicketsAuthStore.isConnected
                self.ticketStatusFetch = [:]
            } catch {
                self.jiraAuthError = error.localizedDescription
            }
            self.jiraConnecting = false
        }
    }

    /// Disconnect: delete every Keychain item for the Jira connector; rows lose status.
    func disconnectJira() {
        jiraAuth?.cancel()
        jiraAuth = nil
        jiraConnecting = false
        TicketsAuthStore.clear()
        ticketsConnected = false
        jiraHasClientSecret = false
        ticketStatusCache = [:]
        ticketStatusFetch = [:]
        reapplyTicketStatuses()
    }

    private var lastIndexSignature = ""

    /// Donate the current sessions to Spotlight's semantic index (App Intents
    /// `IndexedEntity`), so they're discoverable and referenceable by natural language.
    /// Throttled: only re-index when the set or a session's title/status changes.
    private func reindexSpotlight() {
        let list = sessions.sessions
        let signature = list
            .map { "\($0.id)|\($0.displayTitle)|\($0.status.rawValue)|\($0.gitBranch ?? "")" }
            .joined(separator: ";")
        guard signature != lastIndexSignature else { return }
        lastIndexSignature = signature
        let entities = list.map(AgentSessionEntity.init)
        Task {
            if entities.isEmpty {
                try? await CSSearchableIndex.default().deleteAllSearchableItems()
            } else {
                try? await CSSearchableIndex.default().indexAppEntities(entities)
            }
        }
    }

    /// Absolute path to the bundled hook helper. `HookSettings` composes the per-event
    /// commands from it, so adding a governed event never touches this. nil if the helper
    /// isn't present (e.g. unit tests) → no injection.
    static func hookHelperPath() -> String? {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/admiral-hook").path
        guard FileManager.default.isExecutableFile(atPath: helper) else { return nil }
        return helper
    }

    /// Copy the bundled `admiral` mod to `<support>/mods/admiral` and return that path, which
    /// every claude tab gets as `--plugin-dir`. Copied out (fresh each launch, so an app update
    /// ships the new mod) because claude writes type files into a plugin folder, and the app
    /// bundle must stay as signed. nil when the bundle has no mod or the copy failed.
    static func installMod(supportDir: URL) -> String? {
        guard let source = Bundle.main.resourceURL?.appendingPathComponent("admiral-mod"),
              FileManager.default.fileExists(atPath: source.path) else { return nil }
        let dest = supportDir.appendingPathComponent("mods", isDirectory: true)
            .appendingPathComponent("admiral", isDirectory: true)
        let fm = FileManager.default
        try? fm.removeItem(at: dest)
        do {
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: dest)
        } catch { return nil }
        return dest.path
    }

    /// Path to the bundled bridge MCP relay, injected per session via `--mcp-config`. nil when
    /// the helper isn't present, so SessionManager skips the injection rather than break launch.
    static func bridgeMCPCommand() -> String? {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/admiral-bridge-mcp").path
        guard FileManager.default.isExecutableFile(atPath: helper) else { return nil }
        return helper
    }

    /// Path to the bundled client-tool MCP relay. Injected only on API tool tabs, as the
    /// `client` server. nil when the helper isn't present, so those tabs launch without it
    /// rather than pointing `--mcp-config` at a missing binary.
    static func clientMCPCommand() -> String? {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/admiral-client-mcp").path
        guard FileManager.default.isExecutableFile(atPath: helper) else { return nil }
        return helper
    }

    /// Resolve the real `claude` binary path (the user's `claude` is a zsh function;
    /// `whence -p` returns the external command's path, ignoring it).
    static func resolveClaude() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-ic", "whence -p claude"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return "claude"
        }
        // The interactive shell can interleave shell-integration escape codes, so
        // tokenize on whitespace + control chars and find the absolute claude path.
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let separators = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        let token = text
            .components(separatedBy: separators)
            .first { $0.hasPrefix("/") && $0.hasSuffix("/claude") }
        return token ?? "claude"
    }
}

/// A drag as AppKit hands it to its destination, without a mouse: `-probeFileDrop` calls the
/// terminal's `draggingEntered`/`performDragOperation` with it. The terminal reads only the
/// pasteboard and the source's offered operations; the rest just satisfies the protocol.
@MainActor
private final class ProbeDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingSourceOperationMask: NSDragOperation

    init(_ pasteboard: NSPasteboard, offering operations: NSDragOperation) {
        draggingPasteboard = pasteboard
        draggingSourceOperationMask = operations
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 0 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
        classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    func resetSpringLoading() {}
}
