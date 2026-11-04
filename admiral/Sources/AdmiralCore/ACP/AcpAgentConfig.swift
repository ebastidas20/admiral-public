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

    /// The agent ignores `--dangerously-skip-permissions`; permissions are set via `defaultMode`.
    public var passesIgnoredSkipPermissionsFlag: Bool {
        launch.args.contains("--dangerously-skip-permissions")
    }
}
