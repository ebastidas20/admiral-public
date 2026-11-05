import Foundation

/// The registry and source of truth for Admiral's sessions. Owns the session list,
/// drives launch/commission through a `TerminalHost`, and resolves transcripts.
/// `@MainActor` so SwiftUI can observe it directly.
@MainActor
public final class SessionManager: ObservableObject {
    @Published public private(set) var sessions: [AgentSession] = []
    /// The selected session. Setting it marks that session "seen", clearing its unseen-work
    /// dot — this is the single chokepoint every selection path (sidebar, keyboard, a
    /// notification click, commission/fork) funnels through.
    @Published public var selectedID: UUID? {
        didSet {
            guard let id = selectedID else { return }
            update(id) { if $0.hasUnseenWork { $0.hasUnseenWork = false } }
        }
    }
    @Published public private(set) var conversations: [UUID: Conversation] = [:]
    /// Each session's chat (its ledger, folded) — what the Chat view draws.
    @Published public private(set) var chats: [UUID: ChatTranscript] = [:]

    /// Each live tab's driver — the one place its input goes. Which kind it is (PTY today)
    /// is decided when the tab is launched, so no input funnel asks again.
    var drivers: [UUID: SessionDriver] = [:]
    private var chatRefreshingIDs: Set<UUID> = []
    private var resolvingIDs: Set<UUID> = []
    private var refreshingIDs: Set<UUID> = []
    private var touchedRefreshingIDs: Set<UUID> = []
    private var branchRefreshingIDs: Set<UUID> = []
    private var lastBranchRefresh: [UUID: Date] = [:]
    /// Sessions whose footprint has been seeded from their existing transcript (one-time).
    private var backfilledIDs: Set<UUID> = []
    private let host: TerminalHost
    public let claudeHome: URL
    private let executablePath: String
    /// Environment entries injected into every spawned agent (notably a full PATH, so
    /// a Finder-launched app's node-based `claude` can find `node` and its tools).
    private let environmentOverrides: [String: String]
    /// The launch recipe used when a commission caller doesn't pass one. Set by the app
    /// to match `executablePath` (the zsh wrapper), so EVERY entry point — UI, restore,
    /// bridge, intents — spawns the same argv. Without this, the bridge fell back to the
    /// `.claudeCode` static (claude's own flags) while the executable was `/bin/zsh`,
    /// so zsh got `--permission-mode` as an option ("no such option: permission_mode").
    private let defaultAgentType: AgentType
    /// When set, wins over `defaultAgentType` and is re-evaluated at EVERY commission — the
    /// app passes a closure that re-reads `LaunchOptionsStore`, so a Settings → Sessions
    /// change applies to the next session without a relaunch.
    private let defaultAgentTypeProvider: (() -> AgentType)?
    /// Seconds a scratch tab may sit idle before `reapIdleScratchTabs` closes it.
    /// Same provider pattern as `defaultAgentTypeProvider`: re-read at every sweep so a
    /// Settings → Bridge & API edit applies live. nil = `IdleReapPolicy.idleThreshold`.
    private let idleReapThresholdProvider: (() -> TimeInterval)?
    let appearanceStore: SessionAppearanceStore
    let openSessionsStore: OpenSessionsStore
    /// Base dir for per-session Admiral state (hook log + injected settings). Injected so
    /// tests use a temp dir. Public so the tripwire store and hook helper agree on the base.
    public let supportDir: URL
    /// The PostToolUse hook command Admiral injects via `--settings` (nil = no injection;
    /// set only by the app for the zsh/claude recipe). See `commission`.
    private let hookHelper: String?
    /// Path to the bundled `admiral-bridge-mcp` relay, injected per managed session via
    /// `--mcp-config` so claude reaches THIS instance's bridge natively (nil = no injection;
    /// set only by the app for the zsh/claude recipe).
    private let bridgeMCPCommand: String?
    /// Path to `admiral-client-mcp`, added as the `client` server on API tool tabs only.
    private let clientMCPCommand: String?
    /// Unix socket the client MCP process parks `tools/call` on. Nil in tests that don't
    /// start the broker socket; the MCP config then omits `ADMIRAL_CLIENT_SOCKET`.
    private let clientToolSocketPath: String?
    /// Parks client `tools/call`s for every tab. The HTTP endpoint and the broker socket
    /// share this instance; it is not the bridge MCP server.
    public let clientToolBroker = ClientToolBroker()
    /// Persists each session's touched-repo footprint across relaunch (keyed by session id),
    /// so a resumed session restores the repos it had written to instead of starting empty.
    let touchedReposStore: TouchedReposStore
    /// Looks a CC Switch provider up by id, so the relaunch paths (reload, fork, restore) can
    /// recover the env a session was launched with — only its id is worth keeping on the
    /// session. Re-read per call, like `defaultAgentTypeProvider`, so a token rotated in CC
    /// Switch reaches the next relaunch. Nil = no catalog (tests, direct spawns).
    private let providerResolver: ((String) -> CCSwitchProvider?)?
    /// Every CC Switch provider on this machine, from the database Settings → Sessions names.
    /// A scheduled run resolves its custom model (by id or name) against it.
    public var providerCatalog: () -> [CCSwitchProvider] = { CCSwitchCatalog.load() }
    /// Settings → Sessions "accept messages from other sessions", re-read at every
    /// commission like the launch recipe. Off unless the app wires it (tests, direct spawns).
    public var acceptPeerMessages: () -> Bool = { false }
    /// The bundled `admiral` Claude Code mod, loaded into every managed session with
    /// `--plugin-dir`. Nil = none (tests, direct spawns).
    public var modDir: String?
    /// Settings → Bridge & API "redact structured output in the event stream".
    /// Read by `syncRedactionFlags`.
    public var redactReplies: () -> Bool = { false }
    /// Puts a message on a session's messaging socket. Swappable so tests can see what went
    /// over the socket without a live claude.
    public var sendPeerMessage: (_ body: String, _ file: ClaudeSessionFile, _ claudeHome: URL) throws -> Void = {
        try ClaudeMessagingSocket.send($0, to: $1, from: "Admiral", claudeHome: $2)
    }
    /// Starts an ACP agent: its config (cwd already the tab's) and the tab's log file, which
    /// gets the agent's stderr. Swappable so tests hand out a scripted agent.
    public var acpTransportFactory: (AcpAgentConfig, URL) throws -> AcpTransport = {
        try ProcessAcpTransport(command: $0.launch, env: $0.env, logURL: $1)
    }
    /// The configured ACP agents (Settings → Agents), re-read per call so restore, reload and
    /// fork find an agent edited since launch. None unless the app wires it.
    public var acpAgents: () -> [AcpAgentConfig] = { [] }
    /// How commands reach an ACP agent's environment (its exec command), or nil when it has
    /// none. The one place an ACP tab's runner is made — hooks, probes and branch refresh all
    /// take it from here. Swappable so tests never spawn `docker exec`.
    public var acpRunnerFactory: (AcpAgentConfig) -> CommandRunner? = { agent in
        agent.effectiveExec.map { ExecCommandRunner(exec: $0) }
    }
    /// The session bridge an ACP tab's agent reaches Admiral's tools on, for a tab's token.
    /// Nil (or a nil answer) = no MCP server: the listener is not running.
    public var sessionBridge: ((_ token: String) -> AcpMCPServer?)? = nil

    public init(
        host: TerminalHost,
        claudeHome: URL = SessionManager.defaultClaudeHome,
        executablePath: String,
        environmentOverrides: [String: String] = [:],
        defaultAgentType: AgentType = .claudeCode,
        defaultAgentTypeProvider: (() -> AgentType)? = nil,
        idleReapThresholdProvider: (() -> TimeInterval)? = nil,
        appearanceStore: SessionAppearanceStore = SessionAppearanceStore(),
        openSessionsStore: OpenSessionsStore = OpenSessionsStore(),
        supportDir: URL = AdmiralPaths.defaultSupportDir,
        hookHelper: String? = nil,
        bridgeMCPCommand: String? = nil,
        clientMCPCommand: String? = nil,
        clientToolSocketPath: String? = nil,
        touchedReposStore: TouchedReposStore = TouchedReposStore(),
        providerResolver: ((String) -> CCSwitchProvider?)? = nil
    ) {
        self.host = host
        self.claudeHome = claudeHome
        self.executablePath = executablePath
        self.environmentOverrides = environmentOverrides
        self.defaultAgentType = defaultAgentType
        self.defaultAgentTypeProvider = defaultAgentTypeProvider
        self.idleReapThresholdProvider = idleReapThresholdProvider
        self.appearanceStore = appearanceStore
        self.openSessionsStore = openSessionsStore
        self.supportDir = supportDir
        self.hookHelper = hookHelper
        self.bridgeMCPCommand = bridgeMCPCommand
        self.clientMCPCommand = clientMCPCommand
        self.clientToolSocketPath = clientToolSocketPath
        self.touchedReposStore = touchedReposStore
        self.providerResolver = providerResolver
    }

    /// The provider a session was launched on, re-resolved from the catalog.
    private func provider(for session: AgentSession) -> CCSwitchProvider? {
        session.providerID.flatMap { providerResolver?($0) }
    }

    nonisolated public static var defaultClaudeHome: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }

    public var selectedSession: AgentSession? {
        guard let id = selectedID else { return nil }
        return sessions.first { $0.id == id }
    }

    /// The selected tab when it is a scratch tab — what ⌘S promotes. The Session menu item and
    /// the ⌘/ palette row both ask this, so neither offers to promote a regular tab.
    public var selectedScratchTab: AgentSession? {
        selectedSession.flatMap { $0.scratch ? $0 : nil }
    }

    /// The PTY handle behind a tab, for the callers that embed or probe the terminal itself.
    public func handle(for id: UUID) -> TerminalHandle? { (drivers[id] as? PTYSessionDriver)?.handle }

    /// A PTY tab's driver. It reads the tab's record and `sendPeerMessage` at delivery time.
    private func ptyDriver(_ id: UUID, handle: TerminalHandle) -> PTYSessionDriver {
        PTYSessionDriver(
            host: host, handle: handle, claudeHome: claudeHome,
            session: { [weak self] in self?.sessions.first { $0.id == id } },
            sendPeerMessage: { [weak self] body, file, home in
                // Gone = not sent: throwing makes the driver type it rather than call it delivered.
                guard let self else { throw CancellationError() }
                try self.sendPeerMessage(body, file, home)
            })
    }

    // MARK: - Lifecycle

    /// Placeholder in an agent's `defaultArgs` that commission swaps for a freshly
    /// generated session id, so the transcript path is deterministic per terminal.
    nonisolated public static let sessionIDPlaceholder = "{{ADMIRAL_SESSION_ID}}"

    /// Placeholder in an agent's `defaultArgs` that commission swaps for the tab's display
    /// name (shell-quoted), passed to claude via `--name` so `claude --resume`, the session
    /// picker, and the statusline show the same name Admiral shows. Recipes without it (bash,
    /// the direct-spawn/test arms) are unaffected — the substitution is a no-op.
    nonisolated public static let sessionNamePlaceholder = "{{ADMIRAL_SESSION_NAME}}"

    /// The values `commission` splices into the launch command line bare: a session id must
    /// parse as a UUID (hex and dashes only), a model must be a `ScheduleModel` and an effort a
    /// `ScheduleEffort`. Nil or empty model/effort means "no flag" and passes.
    nonisolated public static func launchValuesValid(sessionID: String?, model: String?, effort: String?) -> Bool {
        if let sessionID, UUID(uuidString: sessionID) == nil { return false }
        if let model, !model.isEmpty, ScheduleModel(rawValue: model) == nil { return false }
        if let effort, !effort.isEmpty, ScheduleEffort(rawValue: effort) == nil { return false }
        return true
    }

    /// Sessions whose real `claude` child pid has been resolved (so the tree walk stops).
    private var claudePIDResolved: Set<UUID> = []

    /// Env vars that mark "running inside a Claude Code session" — stripped from a hosted
    /// agent's environment so it doesn't inherit nested/child-session behavior (notably,
    /// not persisting its transcript). `ANTHROPIC_*` and `CLAUDE_CONFIG_DIR` are kept.
    /// Env keys that disable chalk / Ink color even when COLORTERM advertises truecolor.
    static func isColorKiller(_ key: String) -> Bool {
        switch key {
        case "NO_COLOR", "NODE_DISABLE_COLORS": return true
        default: return false
        }
    }

    static func stripColorKillers(_ env: inout [String: String]) {
        for key in Array(env.keys) where isColorKiller(key) {
            env.removeValue(forKey: key)
        }
        // FORCE_COLOR=0 means "no color"; any other value is left for strip+reassign below.
        if env["FORCE_COLOR"] == "0" {
            env.removeValue(forKey: "FORCE_COLOR")
        }
    }

    static func inheritedAgentMarkers(_ key: String) -> Bool {
        key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE") || key == "CLAUDE_EFFORT" || key == "AI_AGENT"
    }

    /// Whether a UTF-8 locale must be injected. True unless `LC_ALL`, `LC_CTYPE`, or `LANG`
    /// already names a UTF-8 codeset — in which case the user's choice is left untouched.
    static func needsUTF8Locale(_ env: [String: String]) -> Bool {
        !["LC_ALL", "LC_CTYPE", "LANG"].contains { key in
            guard let value = env[key]?.lowercased() else { return false }
            return value.contains("utf-8") || value.contains("utf8")
        }
    }

    /// `<language>_<REGION>.UTF-8` for the current system locale, falling back to the
    /// always-installed `en_US.UTF-8`. Only the `.UTF-8` codeset matters for the mojibake;
    /// the region just keeps the agent's number/date formatting sensible.
    static var preferredUTF8Locale: String {
        if let language = Locale.current.language.languageCode?.identifier,
           let region = Locale.current.region?.identifier,
           !language.isEmpty, !region.isEmpty {
            return "\(language)_\(region).UTF-8"
        }
        return "en_US.UTF-8"
    }

    /// Commission a session and spawn its agent in a PTY.
    ///
    /// - `sessionID`: reuse this id (nil generates a fresh one). Passed to claude via
    ///   `--session-id`, so the transcript filename is known up front.
    /// - `resume`: restore the prior conversation with `--resume <id>` instead of
    ///   creating a new one. ONLY pass `resume: true` when that transcript actually
    ///   exists — resuming a never-written id errors ("session not found"); recreating
    ///   it with `--session-id` reopens it fresh.
    /// - `provider`: a CC Switch config this session alone talks to, injected through its
    ///   own `--settings` file. Nil (the default) is stock Anthropic. Only a managed claude
    ///   session can carry one — that file is what delivers it.
    /// - `model`/`effort`: the claude model (`--model`, a `ScheduleModel` alias) and effort
    ///   level (`--effort`, a `ScheduleEffort` value) this session runs with. Nil means no
    ///   flag, so claude's own defaults decide. Only a managed claude session can carry them.
    /// - `clientTools`: an API tool tab. Before spawn, the absolute cwd is marked trusted
    ///   in `~/.claude.json` so Claude Code does not block on the workspace trust dialog.
    ///   Nil (every other tab) does not touch that file.
    @discardableResult
    public func commission(
        callsign: String, cwd: String, agentType: AgentType? = nil,
        sessionID: String? = nil, resume: Bool = false,
        teamName: String? = nil, scratch: Bool = false,
        provider: CCSwitchProvider? = nil,
        model: String? = nil, effort: String? = nil,
        clientTools: [ClientToolSpec]? = nil
    ) -> AgentSession {
        // Fall back to the manager's configured recipe (matches `executablePath`). The
        // provider is consulted fresh so launch-options edits reach the next commission.
        let agentType = agentType ?? defaultAgentTypeProvider?() ?? defaultAgentType
        // Everything below is spliced into a `zsh -ilc` command line. A session id, model or
        // effort that is not what it claims (a restored record, a runs.jsonl entry, a schedule
        // file) is refused: nothing is spawned, and the returned session carries no claude
        // session id and is never added — callers already treat that as "no tab started".
        guard Self.launchValuesValid(sessionID: sessionID, model: model, effort: effort) else {
            return AgentSession(callsign: callsign, agentType: agentType, cwd: cwd, status: .shell)
        }
        let sessionID = sessionID ?? UUID().uuidString.lowercased()
        let managesSessionID = agentType.defaultArgs.contains { $0.contains(Self.sessionIDPlaceholder) }
        // claude is launched plainly — `team` is a bridge/Admiral-level label only (used
        // by the roster, the team chip, and hail), never passed to claude.
        var args = agentType.defaultArgs.map {
            $0.replacingOccurrences(of: Self.sessionIDPlaceholder, with: sessionID)
        }
        if resume {
            args = args.map { $0.replacingOccurrences(of: "--session-id \(sessionID)", with: "--resume \(sessionID)") }
        }

        // Restore this SESSION's own saved name/color/icon (keyed by its persistent id).
        // A brand-new terminal has a fresh id with nothing saved, so it starts clean; a
        // restored session reuses its id and gets its own look back. Two terminals in the
        // same folder never collide. Bash tabs now get a persistent id too (for restore),
        // so their name/color/icon round-trip the same way.
        let appearance = appearanceStore.appearance(forSession: sessionID)
        let label = teamName?.trimmingCharacters(in: .whitespaces)
        // A tab must never be nameless: callers like the bridge `commission` tool can pass
        // an empty callsign. Fall back to the working-dir folder, then a generic label.
        // Every path through here (New form, MCP, API scratch, restore, fork) gets the same
        // station-name rules as a rename, so no tab name ever holds a space.
        let resolvedCallsign = Self.resolvedCallsign(callsign, cwd: cwd)
        var session = AgentSession(
            callsign: resolvedCallsign, agentType: agentType, cwd: cwd,
            teamName: (label?.isEmpty ?? true) ? nil : label,
            // Persistent id for EVERY non-test tab (claude + bash): open-sessions restore,
            // appearance, and reorder all key on it. Claude-only features still gate on
            // `managesSessionID` (hooks, transcript, --resume, goals).
            claudeSessionID: sessionID,
            // Start unknown, not optimistically busy: the busy indicator (sidebar comet) must
            // reflect a real "busy" read from the session file, not a default that sticks when
            // the pid/file hasn't resolved yet — otherwise every session looks like it's working.
            spawnedAt: Date(), status: .unknown,
            customName: appearance.name,
            avatarColorHex: appearance.colorHex,
            avatarSymbol: appearance.symbol,
            scratch: scratch
        )
        // Restore this session's touched-repo footprint (managed sessions only) so a resumed
        // session shows the repos it had written to, not an empty panel.
        if managesSessionID {
            session.touchedRepos = touchedReposStore.repos(forSession: sessionID)
        }

        var env = ProcessInfo.processInfo.environment
        // Strip Claude Code's nested-session markers. If Admiral itself was launched from
        // within a Claude Code session, the spawned claude would inherit CLAUDECODE /
        // CLAUDE_CODE_CHILD_SESSION and run as a SUB-session that does NOT persist a
        // transcript — the very file the Transcript view tails. Removing them makes each
        // hosted claude a normal top-level session that writes its transcript to disk.
        for key in env.keys where Self.inheritedAgentMarkers(key) {
            env.removeValue(forKey: key)
        }
        env["TERM"] = "xterm-256color"
        // Advertise 24-bit color. SwiftTerm renders `38;2;R;G;B` at full fidelity, but a TUI
        // only emits it when the environment says the terminal can take it, and every probe
        // keys on COLORTERM: chalk/supports-color (claude) drops to level 2 and Rich (hermes)
        // to EIGHT_BIT without it, quantizing every color onto the coarse 256-cube — Rich even
        // flattens anything under 15% saturation onto the gray ramp, which is what makes the
        // output look washed out. `TERM_PROGRAM=Admiral` means nothing to those probes (they
        // special-case only iTerm.app / Apple_Terminal), so this is the only signal that lands.
        env["COLORTERM"] = "truecolor"
        env["ADMIRAL_SESSION"] = session.token
        env["ADMIRAL_REDACT_FLAG"] = AdmiralPaths.redactRepliesFlag(base: supportDir, token: session.token).path
        env["ADMIRAL_REDACTED_DIR"] = AdmiralPaths.redactedOutputDir(base: supportDir, token: session.token).path
        env["ADMIRAL_OUTPUT_FILE"] = AdmiralPaths.structuredOutputFile(base: supportDir, token: session.token).path
        // Host markers so the bridge (and anything reading `ps eww <pid>`) can tell an
        // Admiral-hosted claude from an iTerm2 one (iTerm2 sets TERM_PROGRAM=iTerm.app).
        env["TERM_PROGRAM"] = "Admiral"
        env["ADMIRAL"] = "1"
        // Guarantee a UTF-8 locale. A macOS GUI app inherits no shell locale, so without this
        // the hosted claude runs under the C locale, where CoreFoundation decodes UTF-8 as
        // Mac Roman — claude's box-drawing and emoji turn into mojibake the moment they
        // round-trip through input (e.g. pasting its own table back into a session). Real
        // terminals (iTerm2, Terminal.app) export a UTF-8 `LANG`; we match them, and defer to
        // any UTF-8 locale already in the environment.
        if Self.needsUTF8Locale(env) { env["LANG"] = Self.preferredUTF8Locale }
        for (key, value) in environmentOverrides { env[key] = value }
        // Color killers often ride in from whatever launched the GUI app (Cursor, a shell
        // with NO_COLOR=1, CI wrappers). chalk / Claude Code treat NO_COLOR or FORCE_COLOR=0
        // as "emit no SGR" — near black-and-white TUI — even when COLORTERM=truecolor is set.
        // Strip them after overrides so a provider env dump cannot reintroduce them, then
        // force level 3 so truecolor survives TERM_PROGRAM=Admiral (unknown to supports-color).
        Self.stripColorKillers(&env)
        env["FORCE_COLOR"] = "3"

        // Sync claude's own session display name to the tab: swap the name placeholder (if the
        // recipe carries one) for the shell-quoted display title, so `--name` reaches claude and
        // `claude --resume`, the session picker, and the statusline all show what Admiral shows.
        // Single-quoted because the name is user text living inside the `zsh -ilc "claude …"`
        // command string (`ShellQuote.single`).
        if managesSessionID {
            let quotedName = ShellQuote.single(session.displayTitle)
            args = args.map { $0.replacingOccurrences(of: Self.sessionNamePlaceholder, with: quotedName) }
        }

        // A scheduled run names the model and effort its claude runs with. The recipe's claude
        // invocation is the last statement, so appended flags land on it. What is spliced is the
        // closed enum's own raw value (a bare lowercase word), never the caller's string.
        if managesSessionID, !args.isEmpty {
            if let model = model.flatMap(ScheduleModel.init(rawValue:)) {
                args[args.count - 1] += " --model \(model.rawValue)"
            }
            if let effort = effort.flatMap(ScheduleEffort.init(rawValue:)) {
                args[args.count - 1] += " --effort \(effort.rawValue)"
            }
        }

        // Install the per-session hooks: write a hooks-only settings file and point `--settings`
        // at it (a quoted path — no JSON in the command string). These are NOT governance (that
        // is hookd, registered globally); they deliver the touched-repos log and the
        // structured-output tripwire, which have no other path into a session. Only for a
        // managed (claude) session — they are meaningless for a plain shell, and appending
        // `--settings …` to `zsh -il` would break the launch. Also requires the app to have wired
        // a hook command (the zsh/claude recipe); tests and direct spawns pass nil. The hook
        // command runs through the launch arg list, so it relies on the user's `claude` function
        // forwarding "$@" (it does — Admiral already passes --session-id this way).
        if managesSessionID, let hookHelper, !args.isEmpty {
            let settingsURL = AdmiralPaths.settingsFile(base: supportDir, token: session.token)
            // Inject `--settings` ONLY if the file was actually written — otherwise claude would
            // refuse to launch on a missing path, turning a best-effort hook into a dead session.
            let accept = acceptPeerMessages()
            if HookSettings.write(helper: hookHelper, providerEnv: provider?.env,
                                  acceptPeerMessages: accept, clientTools: clientTools != nil,
                                  to: settingsURL) {
                args[args.count - 1] += " --settings \(ShellQuote.single(settingsURL.path))"
                session.acceptsPeerMessages = accept
                // Recorded only now: the provider is real once its env is in the file claude
                // will read. A failed write leaves the tab un-badged and on Anthropic rather
                // than labelled with a provider it never reached.
                session.providerID = provider?.id
                session.providerName = provider?.name
            }
        }

        // Register Admiral's own bridge MCP for this session (same as we inject the hook), so
        // it reaches THIS instance's bridge natively — no external bridge dependency.
        // Non-strict for a normal tab: the user's other MCP servers still load. An API tool
        // tab also gets the `client` server and, below, `--strict-mcp-config`. Only inject
        // if the config file was actually written, so a failure degrades to "no bridge"
        // rather than a dead launch.
        let catalogURL = AdmiralPaths.clientToolsFile(base: supportDir, token: session.token)
        var clientServer: BridgeMCPConfig.ClientServer?
        if managesSessionID, clientTools != nil, let clientMCPCommand {
            var mcpEnv = [
                "ADMIRAL_SESSION": session.token,
                "ADMIRAL_CLIENT_CATALOG": catalogURL.path,
            ]
            if let clientToolSocketPath {
                mcpEnv["ADMIRAL_CLIENT_SOCKET"] = clientToolSocketPath
                env["ADMIRAL_CLIENT_SOCKET"] = clientToolSocketPath
            }
            env["ADMIRAL_CLIENT_CATALOG"] = catalogURL.path
            env["MCP_TOOL_TIMEOUT"] = String(ClientToolLimits.mcpTimeoutMilliseconds)
            clientServer = BridgeMCPConfig.ClientServer(
                command: clientMCPCommand, timeoutMs: ClientToolLimits.mcpTimeoutMilliseconds, env: mcpEnv)
        }
        if managesSessionID, !args.isEmpty, bridgeMCPCommand != nil || clientServer != nil {
            let mcpURL = AdmiralPaths.mcpConfigFile(base: supportDir, token: session.token)
            if BridgeMCPConfig.write(bridgeCommand: bridgeMCPCommand, client: clientServer, to: mcpURL) {
                args[args.count - 1] += " --mcp-config \(ShellQuote.single(mcpURL.path))"
            }
        }

        // API tool tab: the catalog has to be on disk before claude's MCP client calls
        // tools/list, which is as soon as the process starts. Built-ins are removed
        // (`--tools ""`), only this mcp-config is loaded, and permission prompts are off
        // so a parked tool call is not a dialog the HTTP client can't answer.
        if managesSessionID, let clientTools, !args.isEmpty {
            ClientToolCatalog.enable(base: supportDir, token: session.token)
            ClientToolCatalog.write(clientTools, base: supportDir, token: session.token)
            args[args.count - 1] += " --strict-mcp-config --permission-mode bypassPermissions --tools \"\""
        }

        // Load Admiral's own mod (PHI-redacted output copies for the SSE feed) into every managed
        // session; whether it acts is the flag file's call, so a toggle reaches running tabs.
        // Only when the folder exists: a missing --plugin-dir is the user's to debug, not ours.
        if managesSessionID, let modDir, !args.isEmpty,
           FileManager.default.fileExists(atPath: modDir) {
            args[args.count - 1] += " --plugin-dir \(ShellQuote.single(modDir))"
        }

        // API tool tab only. Claude Code shows the workspace trust dialog before it
        // writes a session file or starts MCP, and that dialog hangs /v1/messages
        // until turnTimeout. The HTTP client's admiral_cwd is an explicit trust
        // signal for this folder for this session, so the flag is on disk before
        // spawn. A normal commission (fleet tabs, the New form) does not write it.
        // A corrupt config is left untouched and the spawn still happens.
        if clientTools != nil {
            ClaudeProjectTrust.ensureAccepted(
                cwd: cwd, claudeConfigURL: ClaudeProjectTrust.configURL(claudeHome: claudeHome))
        }

        let id = session.id
        let handle = host.spawn(
            executable: executablePath,
            args: args,
            env: env,
            cwd: cwd,
            onExit: { [weak self] _ in
                Task { @MainActor in self?.markStatus(id, .shell) }
            }
        )
        session.claudePID = handle.pid
        drivers[id] = ptyDriver(id, handle: handle)
        sessions.append(session)
        syncRedactionFlags()
        // A scratch tab must not yank focus from whatever the user is doing (the New form
        // selects its own explicitly — the user just asked for it).
        if !scratch { selectedID = id }
        // Remember it so a relaunch can reopen it (claude --resume, or a fresh bash zsh).
        // Scratch tabs stay out of the store until promote().
        if !scratch { persistRecord(of: session) }
        resolveTranscript(for: id)
        // git branch off-main (don't block commission).
        Task.detached(priority: .utility) { [weak self] in
            let branch = Git.branch(at: cwd)
            await MainActor.run { self?.update(id) { $0.gitBranch = branch } }
        }
        return session
    }

    /// A tab's name from what the caller passed: sanitized, else the working-dir folder, else a
    /// generic label — so no tab is nameless and none holds a space.
    static func resolvedCallsign(_ callsign: String, cwd: String) -> String {
        let clean = StationName.sanitize(callsign)
        if !clean.isEmpty { return clean }
        let folder = StationName.sanitize((cwd as NSString).lastPathComponent)
        return (folder.isEmpty || folder == "/") ? "session" : folder
    }

    /// Fork a session: clone its transcript under a fresh id and resume it as a new,
    /// independent session in the same cwd, placed right after the source and selected. The
    /// original keeps running, untouched. No-op if the source has no transcript yet (nothing
    /// to fork). The clone runs off-main (the transcript can be large); the spawn is on-main.
    public func fork(_ id: UUID) {
        guard let source = sessions.first(where: { $0.id == id }) else { return }
        switch source.backend {
        case .pty: forkPTY(source)
        case let .acp(agentName): forkACP(source, agentName: agentName)
        }
    }

    private func forkPTY(_ source: AgentSession) {
        let id = source.id
        guard let sourceSID = source.claudeSessionID,
              hasTranscript(sessionID: sourceSID, cwd: source.cwd) else { return }
        let newID = UUID().uuidString.lowercased()
        let cwd = source.cwd, home = claudeHome, callsign = source.callsign
        let title = source.displayTitle, color = source.avatarColorHex, symbol = source.avatarSymbol
        // A fork of a Kimi tab is a Kimi tab: the clone continues the same conversation, so it
        // must continue it on the same endpoint.
        let sourceProvider = provider(for: source)
        Task.detached(priority: .userInitiated) { [weak self] in
            guard TranscriptFork.clone(sourceID: sourceSID, newID: newID, cwd: cwd, claudeHome: home) != nil
            else { return }
            await MainActor.run {
                guard let self else { return }
                let fork = self.commission(
                    callsign: callsign, cwd: cwd, sessionID: newID, resume: true,
                    provider: sourceProvider)
                self.settleFork(fork.id, of: id, title: title, color: color, symbol: symbol)
            }
        }
    }

    /// A fork's name, look and slot: "<title> (fork)", the source's avatar, right after the
    /// source (commission appends it at the end), and selected.
    func settleFork(_ forkID: UUID, of sourceID: UUID, title: String, color: String?, symbol: String?) {
        rename(forkID, to: "\(title) (fork)")
        setAppearance(forkID, colorHex: color, symbol: symbol)
        if let srcIdx = sessions.firstIndex(where: { $0.id == sourceID }),
           srcIdx + 1 < sessions.count, sessions[srcIdx + 1].id != forkID {
            move(forkID, before: sessions[srcIdx + 1].id)
        }
        selectedID = forkID
    }

    /// Adds a newly launched tab with its driver (nil = a tab that never started), and selects
    /// it unless it is scratch — which must not yank focus from whatever the user is doing.
    func install(_ session: AgentSession, driver: SessionDriver?) {
        if let driver { drivers[session.id] = driver }
        sessions.append(session)
        syncRedactionFlags()
        if !session.scratch { selectedID = session.id }
    }

    /// Register a session created elsewhere (tests / future adoption).
    public func register(_ session: AgentSession, handle: TerminalHandle? = nil) {
        if let handle { drivers[session.id] = ptyDriver(session.id, handle: handle) }
        sessions.append(session)
        if selectedID == nil { selectedID = session.id }
    }

    /// Sessions saved from a previous run, to resume on launch.
    public func restorableSessions() -> [OpenSessionRecord] { openSessionsStore.all() }

    /// Whether claude has written a transcript for this session id in `cwd` — i.e. it can
    /// be `--resume`d. False for an empty session that never had a turn (recreate fresh).
    public func hasTranscript(sessionID: String, cwd: String) -> Bool {
        let path = claudeHome.appendingPathComponent("projects")
            .appendingPathComponent(TranscriptLocator.encodeProjectDir(cwd))
            .appendingPathComponent("\(sessionID).jsonl")
        return FileManager.default.fileExists(atPath: path.path)
    }

    /// Delete a session: terminate its process, drop it from the list, forget it so it
    /// won't be restored next launch, and clear ITS OWN persisted name/color/icon. Other
    /// sessions (even in the same folder) are independent and untouched.
    public func delete(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let session = sessions[index]
        drivers[id]?.terminate()
        if let sid = session.claudeSessionID {
            openSessionsStore.remove(sessionID: sid)
            appearanceStore.remove(forSession: sid)
            touchedReposStore.remove(forSession: sid)
            OutputSchemaStore.set(nil, base: supportDir, session: sid)
        }
        drivers[id] = nil
        clientToolBroker.failAll(token: session.token, message: "session closed")
        // Remove this session's on-disk hook state (log + injected settings).
        let sessionDir = supportDir.appendingPathComponent("sessions").appendingPathComponent(session.token)
        try? FileManager.default.removeItem(at: sessionDir)
        conversations[id] = nil
        claudePIDResolved.remove(id)
        sessions.removeAll { $0.id == id }
        // Follow the deleted tab to its neighbor — the next one (which has shifted into the
        // freed slot), or the previous when it was the last — instead of jumping to the top.
        if selectedID == id {
            selectedID = sessions.isEmpty ? nil : sessions[min(index, sessions.count - 1)].id
        }
        onDelete(session)
    }

    /// Told after every `delete` — the sidebar, the bridge, the scratch reaper and `closeTab`
    /// all funnel through it — so a tab's groups can let it go. Not called on app quit.
    public var onDelete: (AgentSession) -> Void = { _ in }

    /// Snapshot allowlisted TUIs in bash tabs into the open-sessions store, then kill every
    /// live process group. Call on app quit (before process teardown) so bash tabs can
    /// reopen `k9s`/etc. on the next launch. Claude tabs still resume from transcript.
    public func terminateAll(bashRestoreEnabled: Bool, bashRestoreAllowlist: Set<String>) {
        persistBashRestoreCommands(enabled: bashRestoreEnabled, allowlist: bashRestoreAllowlist)
        for driver in drivers.values { driver.terminate() }
    }

    /// Kill every live session's process without refreshing bash restore commands.
    public func terminateAll() {
        for driver in drivers.values { driver.terminate() }
    }

    /// For each bash tab, record an allowlisted foreground TUI basename (or clear it).
    public func persistBashRestoreCommands(enabled: Bool, allowlist: Set<String>) {
        let snap = ProcessTree.snapshot()
        for s in sessions where s.agentType.id == "bash" {
            guard let sid = s.claudeSessionID else { continue }
            let pid = drivers[s.id]?.pid ?? s.claudePID
            let cmd: String?
            if enabled, let pid {
                cmd = ProcessTree.allowlistedRestoreCommand(
                    spawnPid: pid, allowlist: allowlist, snapshot: snap)
            } else {
                cmd = nil
            }
            openSessionsStore.setRestoreCommand(sessionID: sid, command: cmd)
        }
    }

    /// Reload a session in place: kill its process tree and relaunch it as the SAME session —
    /// resuming its transcript at the same id, in the same slot, with its saved name/color/team
    /// and re-injected hooks + bridge MCP. This is the per-tab equivalent of what a full app
    /// restart does (terminate every child, then restore-resume each), so a wedged agent can be
    /// bounced without losing its conversation. Managed (claude) sessions only — an unmanaged
    /// shell has no transcript to resume. No-op for an unknown or unmanaged id.
    @discardableResult
    public func reload(_ id: UUID) -> AgentSession? {
        guard let index = sessions.firstIndex(where: { $0.id == id }),
              let sid = sessions[index].claudeSessionID else { return nil }
        let old = sessions[index]
        // How it comes back is decided before anything is torn down: an ACP tab whose agent is
        // no longer configured cannot relaunch, so it is left running rather than killed.
        let relaunch: () -> AgentSession
        switch old.backend {
        case .pty:
            relaunch = { [unowned self] in
                // Resuming if a transcript exists (else recreate fresh at that id — the same
                // rule launch-time restore uses). commission restores the saved
                // appearance/team/footprint and re-injects the hook settings + bridge MCP + --name.
                commission(
                    callsign: old.callsign, cwd: old.cwd, agentType: old.agentType,
                    sessionID: sid, resume: hasTranscript(sessionID: sid, cwd: old.cwd),
                    teamName: old.teamName, scratch: old.scratch, provider: provider(for: old))
            }
        case let .acp(agentName):
            guard let agent = acpAgent(named: agentName) else { return nil }
            let start: AcpSessionController.Start = old.acpSessionID.map { .restore(acpSessionID: $0) } ?? .new
            relaunch = { [unowned self] in
                commissionACP(agent: agent, callsign: old.callsign, cwd: old.cwd, start: start,
                              scratch: old.scratch, sessionID: sid, teamName: old.teamName)
            }
        }
        let priorSelection = selectedID
        // The tab that followed this one — used to restore position after commission appends the
        // relaunched session at the end (nil when it was already last, so no move is needed).
        let successorID = index + 1 < sessions.count ? sessions[index + 1].id : nil

        // Kill the running process group (claude + its node/MCP grandchildren), exactly like app
        // quit's `terminateAll`. Drop the live session and its in-flight resolution state, but keep
        // EVERY persisted store (appearance, open-sessions, footprint, hook dir) so the relaunch
        // restores the tab unchanged.
        drivers[id]?.terminate()
        drivers[id] = nil
        conversations[id] = nil
        claudePIDResolved.remove(id)
        backfilledIDs.remove(id)
        sessions.remove(at: index)

        // Relaunch at the same local session id.
        let fresh = relaunch()

        // Put it back where it was (commission appended it last), then restore the prior selection
        // — reloading a background tab must not steal focus from the tab you're on.
        if let successorID, successorID != fresh.id { move(fresh.id, before: successorID) }
        selectedID = (priorSelection == id) ? fresh.id : priorSelection
        return fresh
    }

    /// Promote a scratch tab to a permanent one: it joins the persisted tab
    /// list (so it restores on relaunch), idle monitoring stops (the reap policy only
    /// looks at scratch sessions), and the sidebar shows it as a normal row. The gray
    /// avatar carries over until the user edits it. No-op for non-scratch sessions.
    public func promote(_ id: UUID) {
        guard let s = sessions.first(where: { $0.id == id }), s.scratch,
              s.claudeSessionID != nil else { return }
        update(id) { $0.scratch = false }
        if let promoted = sessions.first(where: { $0.id == id }) { persistRecord(of: promoted) }
        persistAppearance(id)
    }

    /// Make every tab's redact-replies flag match the setting — the one place that decides it.
    /// Called after a commission and a settings toggle; the mod inside each running claude
    /// reads it at its next turn end.
    public func syncRedactionFlags() {
        let redact = redactReplies()
        for s in sessions {
            let flag = AdmiralPaths.redactRepliesFlag(base: supportDir, token: s.token)
            if redact {
                if !FileManager.default.fileExists(atPath: flag.path) {
                    FileManager.default.createFile(atPath: flag.path, contents: Data())
                }
            } else {
                try? FileManager.default.removeItem(at: flag)
            }
        }
    }

    /// Reap scratch tabs that have gone idle (no output, no programmatic input for the
    /// configured threshold — 30 minutes unless Settings → Bridge & API says otherwise)
    /// and have no open goals — same teardown as Delete, no confirmation. Called on the
    /// app tick; `now` is injectable for tests.
    public func reapIdleScratchTabs(now: Date = Date()) {
        let threshold = idleReapThresholdProvider?() ?? IdleReapPolicy.idleThreshold
        let goals = GoalsStore(base: supportDir)
        let withOpenGoals = Set(sessions.filter { s in
            guard s.scratch, let sid = s.claudeSessionID else { return false }
            return goals.goals(forSession: sid)?.outstanding.isEmpty == false
        }.map(\.id))
        for id in IdleReapPolicy.reapable(
            sessions: sessions, selectedID: selectedID, withOpenGoals: withOpenGoals,
            now: now, threshold: threshold
        ) {
            delete(id)
        }
    }

    /// Reorder: move a session to just before another (drag-to-reorder in the list).
    /// Persists the new order so it survives relaunch.
    public func move(_ id: UUID, before targetID: UUID) {
        guard id != targetID, let from = sessions.firstIndex(where: { $0.id == id }) else { return }
        let item = sessions.remove(at: from)
        if let to = sessions.firstIndex(where: { $0.id == targetID }) { sessions.insert(item, at: to) }
        else { sessions.append(item) }
        openSessionsStore.reorder(sessions.compactMap { $0.claudeSessionID })
    }

    /// Move a session within the list by `delta` positions (negative = toward the top),
    /// clamping at the ends. Persists the new order. Used by the ⇧⌘↑/⇧⌘↓ keyboard reorder.
    /// Returns whether anything moved.
    @discardableResult
    public func move(_ id: UUID, by delta: Int) -> Bool {
        guard let from = sessions.firstIndex(where: { $0.id == id }) else { return false }
        let to = min(max(from + delta, 0), sessions.count - 1)
        guard to != from else { return false }
        let item = sessions.remove(at: from)
        sessions.insert(item, at: to)
        openSessionsStore.reorder(sessions.compactMap { $0.claudeSessionID })
        return true
    }

    // MARK: - Customization (name / color / icon, persisted per cwd)

    /// Rename a session — the INTENT path. An empty name clears the override (back to
    /// title/callsign), and the claude inside is told either way.
    ///
    /// The push lives here rather than in any one caller so the sidebar edit, the rename
    /// command, agent naming at spawn, and fork naming all reach claude identically. Use
    /// `adoptName` instead when claude is the one that renamed itself.
    public func rename(_ id: UUID, to name: String) {
        let clean = StationName.sanitize(name)
        update(id) { $0.customName = clean.isEmpty ? nil : clean }
        persistAppearance(id)
        // Claude has no "unset", so a cleared override pushes the name we fall back to
        // displaying; otherwise the two sides drift apart on the next glance.
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        pushName(session.displayTitle, to: session)
    }

    /// Adopt a name claude gave ITSELF — the OBSERVATION path, no push.
    ///
    /// Without this split, capturing claude's rename would echo it straight back at claude.
    /// A name that does not survive sanitizing is corrected rather than adopted dirty: the
    /// invariant is that both sides hold the same string, and only one shape is valid.
    public func adoptName(_ id: UUID, _ name: String) {
        let clean = StationName.sanitize(name)
        guard !clean.isEmpty else { return }
        update(id) { $0.customName = clean }
        persistAppearance(id)
        if clean != name, let session = sessions.first(where: { $0.id == id }) {
            pushName(clean, to: session)
        }
    }

    /// Tell a session's claude what it is called. Silent when it cannot be reached — a
    /// rename at spawn or fork lands before the socket exists, and the next `refreshStatuses`
    /// reconciles it. A retry queue would only make that race noisier.
    private func pushName(_ name: String, to session: AgentSession) {
        guard let sid = session.claudeSessionID,
              let file = ClaudeSessionFile.all(claudeHome: claudeHome)
                  .first(where: { $0.sessionId == sid && $0.isAddressable })
        else { return }
        try? ClaudeMessagingSocket.rename(name, on: file, claudeHome: claudeHome)
    }

    /// Set the avatar's color (`#RRGGBB`) and/or SF Symbol; nil clears that override.
    public func setAppearance(_ id: UUID, colorHex: String?, symbol: String?) {
        update(id) {
            $0.avatarColorHex = colorHex
            $0.avatarSymbol = symbol
        }
        persistAppearance(id)
    }

    /// Set (or clear) a session's team — a runtime grouping for the bridge's roster and
    /// messaging. No relaunch: the native --team-name (inbox watcher) is fixed at launch,
    /// so this is the bridge-level team label only.
    public func setTeam(_ id: UUID, team: String?) {
        let t = team?.trimmingCharacters(in: .whitespaces)
        update(id) { $0.teamName = (t?.isEmpty ?? true) ? nil : t }
        // Persist the new team into the restore record so it survives relaunch.
        if let s = sessions.first(where: { $0.id == id }), !s.scratch { persistRecord(of: s) }
    }

    /// Writes a tab's restore record — the one place a record is built from a session, so a
    /// rename, team change or promote never drops what an ACP tab needs to come back. An ACP
    /// tab is written only once its agent named the session (`acpSessionID`): before that there
    /// is nothing to resume.
    func persistRecord(of s: AgentSession) {
        guard let sid = s.claudeSessionID else { return }
        var record = OpenSessionRecord(
            cwd: s.cwd, sessionID: sid, callsign: s.callsign, teamName: s.teamName,
            providerID: s.providerID, agentTypeID: s.agentType.id)
        if case let .acp(agentName) = s.backend {
            guard let acpSessionID = s.acpSessionID else { return }
            record.acpAgentName = agentName
            record.acpSessionID = acpSessionID
        }
        openSessionsStore.upsert(record)
    }

    private func persistAppearance(_ id: UUID) {
        // Persist against the session's own id (claude + bash). Missing only for odd
        // register()-ed test sessions that never got a persistent id.
        guard let s = sessions.first(where: { $0.id == id }), let sid = s.claudeSessionID else { return }
        appearanceStore.setAppearance(
            SessionAppearance(name: s.customName, colorHex: s.avatarColorHex, symbol: s.avatarSymbol),
            forSession: sid
        )
    }

    /// Composer / Siri free-text: type the line and submit it. False when nothing took it
    /// (no driver, or an ACP tab whose agent is gone); a PTY tab always takes it.
    @discardableResult
    public func send(_ id: UUID, text: String) -> Bool {
        guard let driver = drivers[id] else { return false }
        update(id) { $0.lastActivityAt = Date() }
        return driver.submitTyped(text)
    }

    /// Type text into a session's terminal (bridge hails / goals / API prompts). A text past
    /// one typed burst goes as a paste (`TerminalPrompt.injected`): typed whole, a 1.2 KB
    /// prompt arrived as its last few bytes.
    ///
    /// Returns false when the session has no driver — nothing was typed. Callers
    /// have to look: a hail that silently evaporates because a driver went missing reads
    /// exactly like one that was delivered.
    @discardableResult
    public func inject(_ id: UUID, text: String, source: String = "admiral") -> Bool {
        inject(id, prompt: .injected(text), source: source)
    }

    /// How Admiral's own messages (PR WATCH, the watchdog) reach a session, decided by the
    /// tab: one launched accepting peer messages gets it on claude's messaging socket, so it
    /// never lands in the input box on top of a half-typed prompt and queues while claude
    /// works; any other tab — or a socket that is not there or refuses — is typed into, so
    /// the message is never lost. Returns false only when neither path reached the session.
    /// The choice of path is the driver's (`PTYSessionDriver.deliver`); the ledger mark and
    /// the activity stamp are made here, once, whichever path it takes.
    @discardableResult
    public func deliver(_ id: UUID, text: String, source: String = "admiral") -> Bool {
        guard let driver = drivers[id] else { return false }
        return marked(id, text: text, source: source) { driver.deliver(text) }
    }

    /// `inject`, with the prompt's pasted part going in as one paste (a long hail's body).
    @discardableResult
    public func inject(_ id: UUID, prompt: TerminalPrompt, source: String = "admiral") -> Bool {
        guard let driver = drivers[id] else { return false }
        return marked(id, text: prompt.text, source: source) { driver.submit(prompt: prompt) }
    }

    /// Runs `submit` with the ledger marked, so the chat shows the prompt as Admiral's, not the
    /// user's. The mark goes down BEFORE the driver call — the prompt hook that consumes it can
    /// run as soon as the text is in — and is taken back when the driver refused the text, so
    /// a stale marker never claims a later identical prompt the user typed. Only a driver that
    /// can fail (ACP: a failed or ended tab) ever refuses; the PTY path is unchanged.
    private func marked(_ id: UUID, text: String, source: String, _ submit: () -> Bool) -> Bool {
        let sid = sessions.first(where: { $0.id == id })?.claudeSessionID
        if let sid { ChatLedger.markInjected(text, source: source, base: supportDir, session: sid) }
        let accepted = submit()
        if accepted {
            update(id) { $0.lastActivityAt = Date() }
        } else if let sid {
            _ = ChatLedger.consumeInjected(prompt: text, base: supportDir, session: sid)
        }
        return accepted
    }

    // MARK: - Chat

    /// Chat composer: type `text` and submit it, as the user would at claude's prompt.
    ///
    /// Typed, never bracket-pasted — claude wraps a paste in `<pasted_content>` and treats it
    /// as untrusted. Each newline goes out as LF (Ctrl+J), which claude's prompt takes as a
    /// newline; only the final CR submits. (`\` + CR, the terminal's Shift+Return, left a
    /// literal backslash in a longer message — probed on 2.1.278.)
    @discardableResult
    public func sendTyped(_ id: UUID, text: String) -> Bool {
        guard let driver = drivers[id] else { return false }
        update(id) { $0.lastActivityAt = Date() }
        return driver.submitTyped(Self.typedText(text))
    }

    /// The question card's Submit: the answers go in as the next prompt. False when the
    /// driver took nothing (an ACP tab with no open question).
    @discardableResult
    public func answerAsk(_ id: UUID, questions: [AskQuestion], answers: [String]) -> Bool {
        guard let driver = drivers[id] else { return false }
        update(id) { $0.lastActivityAt = Date() }
        return driver.answer(questions: questions, answers: answers)
    }

    /// A permission prompt answered from the chat: the agent's "Yes". False when there was
    /// none to answer.
    @discardableResult
    public func allowPermission(_ id: UUID) -> Bool {
        drivers[id]?.allowPermission() ?? false
    }

    /// The bytes `sendTyped` types for `text` (before the submitting CR): CRLF and stray CRs
    /// become LF, since a CR mid-message would submit it early.
    public static func typedText(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Esc: interrupt whatever claude is doing, as the terminal's own Esc does.
    public func interrupt(_ id: UUID) {
        drivers[id]?.interrupt()
    }

    /// Re-read a session's chat ledger. Off-main, with an in-flight guard, like the transcript.
    public func refreshChat(_ id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }), let sid = session.claudeSessionID,
              !chatRefreshingIDs.contains(id) else { return }
        chatRefreshingIDs.insert(id)
        let base = supportDir
        let transcript = session.transcriptPath
        Task.detached(priority: .utility) { [weak self] in
            // The live window: the newest items only (transcript + ledger, `ChatHistory`).
            // Anything older is paged in by the view as the reader scrolls up.
            let chat = ChatHistory.live(base: base, session: sid, transcriptPath: transcript)
            await MainActor.run {
                guard let self else { return }
                self.chatRefreshingIDs.remove(id)
                if self.chats[id] != chat { self.chats[id] = chat }
            }
        }
    }

    /// Visible viewport text for a live terminal, or nil if there is no driver / no screen.
    public func readScreen(_ id: UUID) -> String? {
        drivers[id]?.readScreen()
    }

    /// Send raw key-chord bytes (no Enter). Returns false if the session has no PTY.
    public func sendKeys(_ id: UUID, text: String) -> Bool {
        guard let driver = drivers[id] else { return false }
        update(id) { $0.lastActivityAt = Date() }
        return driver.sendKeys(text)
    }

    // MARK: - Resolution / refresh

    /// Resolve the transcript for a session, then tail it.
    ///
    /// For an Admiral-spawned session (it has a `spawnedAt`) we isolate *this* terminal's
    /// own transcript — the exact `--session-id` file, or the newest `.jsonl` created
    /// at/after the spawn — and never the workspace-newest file (which belongs to some
    /// other session in the same dir). Until claude writes the first turn, this stays nil
    /// and the view shows "waiting" rather than another session's conversation.
    ///
    /// Legacy/adopted sessions (no `spawnedAt`) keep the bridge-style `ResolvePath`:
    /// pid → `sessions/<pid>.json` → newest-in-cwd. Idempotent, called every tick.
    public func resolveTranscript(for id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }),
              session.backend.readsClaudeFiles,
              !resolvingIDs.contains(id),
              !session.cwd.isEmpty else { return }
        // Keep (re)resolving until we've locked the right file. For an own-spawn with a
        // known session id, that means the exact `<sid>.jsonl` — so a creation-date
        // fallback (used before that file appears) UPGRADES to it. Otherwise, resolve once.
        if let spawnedSid = session.claudeSessionID, session.spawnedAt != nil {
            let exact = claudeHome.appendingPathComponent("projects")
                .appendingPathComponent(TranscriptLocator.encodeProjectDir(session.cwd))
                .appendingPathComponent("\(spawnedSid).jsonl").path
            guard session.transcriptPath != exact else { return }
        } else {
            guard session.transcriptPath == nil else { return }
        }
        // Filesystem lookups (and `ps` on the legacy path) must NOT run on the main
        // thread — they froze the UI every tick. Resolve off-main, then hop back.
        resolvingIDs.insert(id)
        let cwd = session.cwd
        let home = claudeHome
        let sessionID = session.claudeSessionID
        let spawnedAt = session.spawnedAt
        let isOwnSpawn = spawnedAt != nil
        let spawnPid = session.claudePID ?? drivers[id]?.pid
        Task.detached(priority: .utility) { [weak self] in
            let path: String?
            if isOwnSpawn {
                // This terminal's own transcript only — no `ps`, no workspace-newest.
                path = TranscriptLocator.resolveOwn(
                    sessionID: sessionID, cwd: cwd, spawnedAt: spawnedAt, claudeHome: home
                )
            } else {
                // claude's real pid may be a descendant of the pid we spawned. Find it,
                // like the bridge's find_claude_pid, then resolve pid → cwd.
                let claudePid: Int32? = spawnPid.map { ProcessTree.findClaudePid(spawnPid: $0) ?? $0 }
                path = TranscriptLocator.resolve(
                    pid: claudePid ?? -1, fallbackCwd: cwd, claudeHome: home
                ).path
            }
            await MainActor.run {
                guard let self else { return }
                self.resolvingIDs.remove(id)
                guard let path,
                      self.sessions.first(where: { $0.id == id })?.transcriptPath != path else { return }
                self.update(id) { $0.transcriptPath = path }
                self.refreshConversation(id)
            }
        }
    }

    /// Set a conversation directly (demo seeding / previews).
    public func setConversation(_ id: UUID, _ conversation: Conversation) {
        conversations[id] = conversation
        if let title = conversation.title { update(id) { $0.title = title } }
    }

    /// Re-parse the transcript into the published conversation model. Reads the file
    /// off-main (large transcripts froze the UI every tick), with an in-flight guard.
    public func refreshConversation(_ id: UUID) {
        guard let path = sessions.first(where: { $0.id == id })?.transcriptPath,
              !refreshingIDs.contains(id) else { return }
        refreshingIDs.insert(id)
        Task.detached(priority: .utility) { [weak self] in
            let convo = TranscriptStore.loadTail(path: path)
            await MainActor.run {
                guard let self else { return }
                self.refreshingIDs.remove(id)
                self.conversations[id] = convo
                if let title = convo.title { self.update(id) { $0.title = title } }
            }
        }
    }

    /// Re-read this session's hook log into `touchedRepos`, preserving any PR status already
    /// fetched (keyed by repo root) so the 30s enrichment isn't wiped each tick. Off-main.
    public func refreshTouchedRepos(for id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }),
              !touchedRefreshingIDs.contains(id) else { return }
        touchedRefreshingIDs.insert(id)
        let base = supportDir
        let token = session.token
        Task.detached(priority: .utility) { [weak self] in
            let repos = TouchedReposReader.read(base: base, token: token)
            await MainActor.run {
                guard let self else { return }
                self.touchedRefreshingIDs.remove(id)
                guard let current = self.sessions.first(where: { $0.id == id }) else { return }
                // Union the live log with the session's current footprint (which includes any
                // repos restored from the persistent store). Existing entries keep their order
                // and their fetched `prs`; a repo touched again this run gains any new branches
                // (never loses one — incl. the current HEAD added by `refreshGitBranch`) and
                // updates its count; repos only in the persistent set are kept; new ones append.
                let liveByRoot = Dictionary(repos.map { ($0.root, $0) }, uniquingKeysWith: { a, _ in a })
                var merged: [TouchedRepo] = []
                var seen = Set<String>()
                for var r in current.touchedRepos {
                    if let live = liveByRoot[r.root] {
                        for b in live.branches where !r.branches.contains(b) { r.branches.append(b) }
                        r.filesWritten = live.filesWritten
                    }
                    merged.append(r)
                    seen.insert(r.root)
                }
                for live in repos where !seen.contains(live.root) {
                    merged.append(live)
                    seen.insert(live.root)
                }
                if merged != current.touchedRepos {
                    self.update(id) { $0.touchedRepos = merged }
                    if let sid = current.claudeSessionID {
                        self.touchedReposStore.setRepos(merged, forSession: sid)
                    }
                }
            }
        }
    }

    /// One-time: seed this session's footprint from its EXISTING transcript (writes that predate
    /// the live hook), so a resumed older session populates the panel. Only ADDS repos not already
    /// known — never overwrites a live/persisted entry. Needs the transcript path (so it retries
    /// until that resolves). Reads + resolves git OFF-MAIN.
    public func backfillTouchedRepos(for id: UUID) {
        guard !backfilledIDs.contains(id),
              let session = sessions.first(where: { $0.id == id }),
              let path = session.transcriptPath else { return }
        backfilledIDs.insert(id)   // mark up front so the tick doesn't relaunch it
        let cwd = session.cwd
        Task.detached(priority: .utility) { [weak self] in
            let backfill = TranscriptFootprint.repos(transcriptPath: path, cwd: cwd)
            await MainActor.run {
                guard let self, !backfill.isEmpty,
                      let current = self.sessions.first(where: { $0.id == id }) else { return }
                var merged = current.touchedRepos
                let known = Set(merged.map(\.root))
                for repo in backfill where !known.contains(repo.root) { merged.append(repo) }
                guard merged != current.touchedRepos else { return }
                self.update(id) { $0.touchedRepos = merged }
                if let sid = current.claudeSessionID {
                    self.touchedReposStore.setRepos(merged, forSession: sid)
                }
            }
        }
    }

    /// Set (or clear) the fetched PR list for one touched repo of a session — one entry per
    /// branch of the repo that has a PR.
    public func setTouchedRepoPRs(_ id: UUID, root: String, prs: [PRStatus]) {
        update(id) { session in
            guard let i = session.touchedRepos.firstIndex(where: { $0.root == root }) else { return }
            session.touchedRepos[i].prs = prs
        }
    }

    /// Replace a session's ticket list (Footprint → Tickets). No-op when unchanged.
    public func setTickets(_ id: UUID, _ tickets: [TicketRef]) {
        guard let current = sessions.first(where: { $0.id == id }), current.tickets != tickets else { return }
        update(id) { $0.tickets = tickets }
    }

    /// Resolve this session's REAL `claude` pid — a descendant of the spawned login
    /// shell, because launching via the user's `claude` function runs claude as a child
    /// (zsh does not `exec` a function). Status reads `sessions/<pid>.json`, keyed by
    /// claude's own pid, so we upgrade `claudePID` from the shell pid to claude's. Walks
    /// the process tree off-main, once per session, then caches. For the exec/direct
    /// recipes the spawn pid IS claude, so the walk just returns it.
    public func resolveClaudePID(for id: UUID) {
        guard !claudePIDResolved.contains(id),
              sessions.first(where: { $0.id == id })?.backend.readsClaudeFiles == true,
              let spawnPid = drivers[id]?.pid else { return }
        Task.detached(priority: .utility) { [weak self] in
            guard let pid = ProcessTree.findClaudePid(spawnPid: spawnPid) else { return }
            await MainActor.run {
                guard let self, self.sessions.contains(where: { $0.id == id }) else { return }
                self.claudePIDResolved.insert(id)
                self.update(id) { $0.claudePID = pid }
            }
        }
    }

    /// Refresh live status (busy/idle) for every session. Match each session to its claude
    /// session file by the STABLE `sessionId` we launched with — not the pid, which needs a
    /// fragile process-tree walk that doesn't survive resume (and left every session stuck on
    /// its seeded status, so the sidebar comet was all-or-nothing). Two app instances can each
    /// write a file for the same id, so keep the freshest by `updatedAt`. Non-managed sessions
    /// (no sessionId) fall back to the pid file.
    public func refreshStatuses() {
        var bySession: [String: ClaudeSessionFile] = [:]
        for f in ClaudeSessionFile.all(claudeHome: claudeHome) {
            guard let sid = f.sessionId else { continue }
            if let cur = bySession[sid], (cur.updatedAt ?? 0) >= (f.updatedAt ?? 0) { continue }
            bySession[sid] = f
        }
        for session in sessions where session.backend.readsClaudeFiles {
            let status: String?
            if let sid = session.claudeSessionID, let file = bySession[sid] {
                status = file.status
                // `updatedAt` advancing = claude produced output or changed state.
                // Stamp it as activity for the scratch-tab idle clock.
                if let updated = file.updatedAt, updated != session.lastFileUpdatedAt {
                    update(session.id) {
                        $0.lastFileUpdatedAt = updated
                        $0.lastActivityAt = Date()
                    }
                }
                // Claude renamed itself (`/rename`, or a peer's control frame). The registry
                // is the only place that shows up, so this tick is where the tab learns.
                if let claudeName = file.name, !claudeName.isEmpty,
                   claudeName != session.displayTitle {
                    adoptName(session.id, claudeName)
                }
            } else if let pid = session.claudePID,
                      let file = ClaudeSessionFile.read(pid: pid, claudeHome: claudeHome) {
                status = file.status
            } else {
                status = nil
            }
            guard let status else { continue }
            applyStatus(SessionStatus(raw: status), to: session.id)
        }
    }

    /// A tab's new live status, from its session file (PTY) or its controller (ACP).
    func applyStatus(_ new: SessionStatus, to id: UUID) {
        update(id) { s in
            // A busy → idle transition is the agent finishing a turn. If it lands on a tab
            // you're not currently on, flag it so the sidebar nags you to come look. The
            // prior-`.busy` requirement keeps restored sessions (which come up
            // `unknown → idle`) from false-flagging.
            if s.status == .busy, new == .idle, id != selectedID {
                s.hasUnseenWork = true
            }
            s.status = new
        }
    }

    /// Re-resolve a session's current git branch — for the session cwd AND every repo in its
    /// footprint. The branch set at commission (and the branch stored per footprint repo) goes
    /// stale the moment a checkout happens — which it does to raise a PR — leaving PR lookups
    /// querying the wrong head, so a freshly-opened PR never surfaces. Refresh them all and
    /// persist when anything changed. Off-main, throttled (`gitAccess`), one refresh in flight
    /// per session, and a no-op when nothing changed — or when the tab has no git to ask.
    public func refreshGitBranch(for id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }),
              let access = gitAccess(for: session),
              !branchRefreshingIDs.contains(id),
              Date().timeIntervalSince(lastBranchRefresh[id] ?? .distantPast) > access.interval else { return }
        branchRefreshingIDs.insert(id)
        lastBranchRefresh[id] = Date()
        let cwd = session.cwd
        let roots = session.touchedRepos.map(\.root)
        let runner = access.runner
        Task.detached(priority: .utility) { [weak self] in
            let sessionBranch = Git.branch(at: cwd, runner: runner)
            var byRoot: [String: String?] = [:]
            for root in roots where byRoot[root] == nil { byRoot[root] = Git.branch(at: root, runner: runner) }
            await MainActor.run {
                guard let self else { return }
                self.branchRefreshingIDs.remove(id)
                guard let current = self.sessions.first(where: { $0.id == id }) else { return }
                var repos = current.touchedRepos
                var changed = current.gitBranch != sessionBranch
                // Add the repo's current HEAD to its branch set (so a freshly-cut PR branch
                // surfaces) — union, never replace, so an earlier branch's PR isn't dropped
                // and the chip no longer alternates between two branches.
                for i in repos.indices {
                    guard let nb = byRoot[repos[i].root], let branch = nb,
                          !repos[i].branches.contains(branch) else { continue }
                    repos[i].branches.append(branch)
                    changed = true
                }
                guard changed else { return }
                self.update(id) {
                    $0.gitBranch = sessionBranch
                    $0.touchedRepos = repos
                }
                if let sid = current.claudeSessionID {
                    self.touchedReposStore.setRepos(repos, forSession: sid)
                }
            }
        }
    }

    // MARK: - Bridge support

    public func session(forToken token: String) -> AgentSession? {
        sessions.first { $0.token == token }
    }

    /// Resolve a station by the name the user actually sees and types — its `displayTitle`
    /// (a rename's `customName`, else the original `callsign`). The bridge identifies
    /// stations by this displayed name so renames in Admiral take effect, matching how the
    /// GUI and App Intents resolve sessions.
    /// Case-insensitive, and an address typed the way a name looked before sanitizing
    /// ("nasty bug") still finds the tab it became ("Nasty-Bug").
    public func session(forCallsign callsign: String) -> AgentSession? {
        let clean = StationName.sanitize(callsign)
        return sessions.first { $0.displayTitle.caseInsensitiveCompare(callsign) == .orderedSame }
            ?? sessions.first { $0.displayTitle.caseInsensitiveCompare(clean) == .orderedSame }
    }

    public func peers(excludingToken token: String) -> [AgentSession] {
        sessions.filter { $0.token != token }
    }

    // MARK: - Private

    private func cwd(of id: UUID) -> String? { sessions.first { $0.id == id }?.cwd }

    private func markStatus(_ id: UUID, _ status: SessionStatus) {
        update(id) { $0.status = status }
    }

    func update(_ id: UUID, _ mutate: (inout AgentSession) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        var session = sessions[index]
        mutate(&session)
        sessions[index] = session
    }
}
