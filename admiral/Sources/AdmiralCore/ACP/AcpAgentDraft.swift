import Foundation

/// Settings → Agents' form: one field per editable value; lists as rows (`args`, and `exec` as
/// its command then its args, one argument per row; `env` and `configOptions` as key/value
/// rows). Converts to and from `AcpAgentConfig` here, so the normalizing is under `swift test`,
/// not in a view.
public struct AcpAgentDraft: Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var command: String
    public var args: AcpArgList
    public var env: AcpPairList
    public var cwd: String
    public var defaultMode: String
    public var configOptions: AcpPairList
    public var mcpCallbackURL: String
    /// Empty = use the exec derived from the launch command (`AcpAgentConfig.derivedExec`).
    public var exec: AcpArgList

    public init(_ config: AcpAgentConfig) {
        id = config.id
        name = config.name
        command = config.launch.command
        args = AcpArgList(config.launch.args)
        env = AcpPairList(config.env)
        cwd = config.cwd
        defaultMode = config.defaultMode ?? ""
        configOptions = AcpPairList(config.defaultConfigOptions)
        mcpCallbackURL = config.mcpCallbackURL
        exec = AcpArgList(config.exec.map { [$0.command] + $0.args } ?? [])
    }

    /// A new agent's starting point: the config's defaults, every field empty — the form's
    /// placeholders show the shape, and no one's container path is pre-filled as a value.
    public static func new() -> AcpAgentDraft {
        AcpAgentDraft(AcpAgentConfig(name: "", launch: AcpCommand(command: ""), cwd: ""))
    }

    public var config: AcpAgentConfig {
        let execValues = exec.values
        let mode = defaultMode.trimmingCharacters(in: .whitespaces)
        return AcpAgentConfig(
            id: id,
            name: name.trimmingCharacters(in: .whitespaces),
            launch: AcpCommand(command: command.trimmingCharacters(in: .whitespaces), args: args.values),
            env: env.map,
            cwd: cwd.trimmingCharacters(in: .whitespaces),
            defaultMode: mode.isEmpty ? nil : mode,
            defaultConfigOptions: configOptions.map,
            mcpCallbackURL: mcpCallbackURL.trimmingCharacters(in: .whitespaces),
            exec: execValues.first.map { AcpCommand(command: $0, args: Array(execValues.dropFirst())) })
    }

    /// What the rows say that the config cannot: a key given twice (the config is a map, so it
    /// would silently keep one). Shown with the config's own errors; Save stays off while any.
    public var validationErrors: [String] {
        Self.duplicates("environment variable", env.duplicateKeys)
            + Self.duplicates("config option", configOptions.duplicateKeys)
    }

    static func duplicates(_ what: String, _ keys: [String]) -> [String] {
        keys.map { "The \(what) \u{201C}\($0)\u{201D} is set more than once." }
    }
}
