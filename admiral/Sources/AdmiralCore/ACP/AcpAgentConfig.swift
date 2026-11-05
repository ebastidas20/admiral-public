import Foundation

/// A process invocation: an executable plus its arguments.
public struct AcpCommand: Codable, Hashable, Sendable {
    public var command: String
    public var args: [String]

    public init(command: String, args: [String] = []) {
        self.command = command
        self.args = args
    }
}

/// Where the agent's files are — decides how git/gh reach them and the bridge URL default.
public enum AcpWorkspace: Codable, Hashable, Sendable {
    /// The agent runs on this Mac: git/gh run directly, `cwd` is a Mac path.
    case thisMac
    /// Somewhere else (a container, a VM, an SSH host). `exec` is the non-interactive prefix that
    /// runs one command there (`docker exec my-container`, `ssh my-host`); nil = none, so git,
    /// branch, touched repos and PR watch stay off.
    case elsewhere(exec: AcpCommand?)

    /// Stored as `{"kind":"thisMac"}` or `{"kind":"elsewhere","exec":{…}}` (`exec` omitted when none).
    private enum CodingKeys: String, CodingKey { case kind, exec }
    private enum Kind: String, Codable { case thisMac, elsewhere }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .thisMac: self = .thisMac
        case .elsewhere: self = .elsewhere(exec: try c.decodeIfPresent(AcpCommand.self, forKey: .exec))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .thisMac:
            try c.encode(Kind.thisMac, forKey: .kind)
        case let .elsewhere(exec):
            try c.encode(Kind.elsewhere, forKey: .kind)
            try c.encodeIfPresent(exec, forKey: .exec)
        }
    }
}

/// One configured ACP (Agent Client Protocol) agent.
public struct AcpAgentConfig: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// How to start the agent (stdio JSON-RPC). Runs on the Mac.
    public var launch: AcpCommand
    /// Environment for the launched process ON THE MAC.
    public var env: [String: String]
    /// Absolute working directory, as the agent sees it.
    public var cwd: String
    /// Where the agent runs: how git/gh reach its files (`execRunnerCommand`).
    public var workspace: AcpWorkspace
    public var defaultConfigOptions: [String: String]
    /// How the agent reaches Admiral's session bridge (:4142).
    public var mcpCallbackURL: String

    public init(
        id: UUID = UUID(),
        name: String,
        launch: AcpCommand,
        env: [String: String] = [:],
        cwd: String,
        workspace: AcpWorkspace = .thisMac,
        defaultConfigOptions: [String: String] = [:],
        mcpCallbackURL: String? = nil
    ) {
        self.id = id
        self.name = name
        self.launch = launch
        self.env = env
        self.cwd = cwd
        self.workspace = workspace
        self.defaultConfigOptions = defaultConfigOptions
        self.mcpCallbackURL = mcpCallbackURL ?? Self.defaultCallbackURL(for: workspace)
    }

    /// The bridge URL a new agent starts with: on this Mac the listener's own loopback address;
    /// elsewhere none — the user must say how that environment reaches this Mac.
    public static func defaultCallbackURL(for workspace: AcpWorkspace) -> String {
        switch workspace {
        case .thisMac: "http://127.0.0.1:4142"
        case .elsewhere: ""
        }
    }

    /// The prefix that runs a command next to the agent: nil on this Mac (run directly), and
    /// elsewhere the configured exec, if any.
    public var execRunnerCommand: AcpCommand? {
        switch workspace {
        case .thisMac: nil
        case let .elsewhere(exec): exec
        }
    }

    // MARK: - Codable (with the one-time migration of the previous shape)

    private enum CodingKeys: String, CodingKey {
        case id, name, launch, env, cwd, workspace, defaultConfigOptions, mcpCallbackURL
        /// Previous version only; read once by the migration, never written.
        case exec, defaultMode
    }

    /// The bridge URL every agent saved before `workspace` existed was given by default.
    static let legacyCallbackURL = "http://host.docker.internal:4142"

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        launch = try c.decode(AcpCommand.self, forKey: .launch)
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        cwd = try c.decode(String.self, forKey: .cwd)
        var options = try c.decodeIfPresent([String: String].self, forKey: .defaultConfigOptions) ?? [:]
        if let workspace = try c.decodeIfPresent(AcpWorkspace.self, forKey: .workspace) {
            self.workspace = workspace
        } else {
            let exec = try c.decodeIfPresent(AcpCommand.self, forKey: .exec)
            workspace = .elsewhere(exec: exec ?? Self.legacyDerivedExec(launch))
        }
        if let mode = try c.decodeIfPresent(String.self, forKey: .defaultMode), options["mode"] == nil {
            options["mode"] = mode
        }
        defaultConfigOptions = options
        mcpCallbackURL = try c.decodeIfPresent(String.self, forKey: .mcpCallbackURL) ?? Self.legacyCallbackURL
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(launch, forKey: .launch)
        try c.encode(env, forKey: .env)
        try c.encode(cwd, forKey: .cwd)
        try c.encode(workspace, forKey: .workspace)
        try c.encode(defaultConfigOptions, forKey: .defaultConfigOptions)
        try c.encode(mcpCallbackURL, forKey: .mcpCallbackURL)
    }

    private static let flagsDropped: Set<String> = ["-i", "--interactive", "-t", "--tty", "-it", "-ti"]
    private static let flagsWithValue: Set<String> = ["-w", "--workdir", "-e", "--env", "-u", "--user", "--env-file"]

    /// MIGRATION ONLY: how the previous version guessed an exec from a `docker exec [flags]
    /// <container> <agent…>` launch (-> `docker exec [flags minus -i/-t] <container>`), so an
    /// agent saved then keeps its git. Nothing else parses launch lines.
    private static func legacyDerivedExec(_ launch: AcpCommand) -> AcpCommand? {
        let base = (launch.command as NSString).lastPathComponent
        guard base == "docker", launch.args.first == "exec" else { return nil }
        var kept = ["exec"]
        var i = 1
        while i < launch.args.count {
            let arg = launch.args[i]
            if flagsDropped.contains(arg) {
                i += 1
            } else if flagsWithValue.contains(arg) {
                kept.append(arg)
                if i + 1 < launch.args.count { kept.append(launch.args[i + 1]) }
                i += 2
            } else if arg.hasPrefix("-") {
                kept.append(arg)
                i += 1
            } else {
                kept.append(arg)
                return AcpCommand(command: launch.command, args: kept)
            }
        }
        return nil  // no container found
    }

    public static let bridgeURLRequired = "bridge URL is required when the agent runs elsewhere"
    public static let bridgeURLNotHTTP = "bridge URL must be an http:// URL"

    /// Human-readable problems; empty = valid.
    public var validationErrors: [String] {
        var errors: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty { errors.append("name is required") }
        if launch.command.trimmingCharacters(in: .whitespaces).isEmpty { errors.append("launch command is required") }
        if !cwd.hasPrefix("/") { errors.append("cwd must be an absolute path as the agent sees it") }
        let url = mcpCallbackURL.trimmingCharacters(in: .whitespaces)
        if url.isEmpty {
            if case .elsewhere = workspace { errors.append(Self.bridgeURLRequired) }
        } else if !Self.isHostURL(url) {
            errors.append(Self.bridgeURLNotHTTP)
        }
        return errors
    }

    /// `http(s)://host[:port]`, an optional trailing `/`, nothing more.
    static func isHostURL(_ text: String) -> Bool {
        guard let c = URLComponents(string: text), let scheme = c.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = c.host, !host.isEmpty,
              c.path.isEmpty || c.path == "/", c.query == nil, c.fragment == nil, c.user == nil
        else { return false }
        return true
    }

    /// `validationErrors`, plus the name's uniqueness among `agents` (case-insensitive, like
    /// `AcpAgentStore.agent(named:)` and every lookup by name): this agent's own saved entry —
    /// same `id` — does not count against it. And a rename is refused while a tab is open on
    /// the old name (`openTabAgents`, the names in open tabs' `.acp(agentName:)`): tabs and their
    /// restore records find their agent by name, so the rename would orphan them (R12). A
    /// change of case only is not a rename — every lookup ignores case. What Settings → Agents
    /// checks before saving.
    public func validationErrors(among agents: [AcpAgentConfig], openTabAgents: [String] = []) -> [String] {
        let name = self.name.trimmingCharacters(in: .whitespaces)
        let same = Self.sameName
        var errors = validationErrors
        if !name.isEmpty, agents.contains(where: { $0.id != id && same($0.name, name) }) {
            errors.append("an agent named \u{201C}\(name)\u{201D} already exists")
        }
        if let saved = agents.first(where: { $0.id == id }), !same(saved.name, name),
           openTabAgents.contains(where: { same($0, saved.name) }) {
            errors.append(Self.renameWithOpenTabs)
        }
        return errors
    }

    public static let renameWithOpenTabs = "Close this agent's tabs before renaming it."

    /// Why this agent cannot be deleted now, or nil: a tab open on it (`openTabAgents`, as for a
    /// rename) would lose its agent — it finds it by name — and break silently (R14).
    public func deletionError(openTabAgents: [String]) -> String? {
        openTabAgents.contains(where: { Self.sameName($0, name) }) ? Self.deleteWithOpenTabs : nil
    }

    public static let deleteWithOpenTabs = "Close this agent's tabs before deleting it."

    /// How every lookup by agent name compares: trimmed, case-insensitive.
    static func sameName(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(b.trimmingCharacters(in: .whitespaces))
            == .orderedSame
    }

    /// The agent ignores `--dangerously-skip-permissions`; a starting mode is set instead.
    public static let ignoredSkipPermissionsNote =
        "This agent ignores --dangerously-skip-permissions. Choose a starting mode below instead."

    public var passesIgnoredSkipPermissionsFlag: Bool {
        launch.args.contains("--dangerously-skip-permissions")
    }
}
