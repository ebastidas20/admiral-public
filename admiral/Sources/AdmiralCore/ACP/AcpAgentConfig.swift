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
    public var defaultMode: String?
    public var defaultConfigOptions: [String: String]
    public var mcpCallbackURL: String
    /// Non-interactive command prefix for running a one-off command next to the agent
    /// (e.g. `docker exec <container>`). nil = none; see `effectiveExec`.
    public var exec: AcpCommand?

    public init(
        id: UUID = UUID(),
        name: String,
        launch: AcpCommand,
        env: [String: String] = [:],
        cwd: String,
        defaultMode: String? = "bypassPermissions",
        defaultConfigOptions: [String: String] = [:],
        mcpCallbackURL: String = "http://host.docker.internal:4142",
        exec: AcpCommand? = nil
    ) {
        self.id = id
        self.name = name
        self.launch = launch
        self.env = env
        self.cwd = cwd
        self.defaultMode = defaultMode
        self.defaultConfigOptions = defaultConfigOptions
        self.mcpCallbackURL = mcpCallbackURL
        self.exec = exec
    }

    private static let flagsDropped: Set<String> = ["-i", "--interactive", "-t", "--tty", "-it", "-ti"]
    private static let flagsWithValue: Set<String> = ["-w", "--workdir", "-e", "--env", "-u", "--user", "--env-file"]

    /// `docker exec [flags] <container> <agent…>` -> `docker exec [flags minus -i/-t] <container>`.
    /// nil unless `launch` is a `docker exec`.
    public static func derivedExec(from launch: AcpCommand) -> AcpCommand? {
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

    public var effectiveExec: AcpCommand? { exec ?? Self.derivedExec(from: launch) }

    /// Human-readable problems; empty = valid.
    public var validationErrors: [String] {
        var errors: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty { errors.append("name is required") }
        if launch.command.trimmingCharacters(in: .whitespaces).isEmpty { errors.append("launch command is required") }
        if !cwd.hasPrefix("/") { errors.append("cwd must be an absolute path as the agent sees it") }
        return errors
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

    /// The agent ignores `--dangerously-skip-permissions`; permissions are set via `defaultMode`.
    public var passesIgnoredSkipPermissionsFlag: Bool {
        launch.args.contains("--dangerously-skip-permissions")
    }
}
