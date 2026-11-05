import Foundation

/// Settings → Agents' "Runs on" choice: the case of `AcpWorkspace` without its exec, which the
/// form keeps in its own rows.
public enum AcpWorkspaceKind: String, CaseIterable, Sendable {
    case thisMac, elsewhere
}

/// Settings → Agents' form: one field per editable value; lists as rows (`args`, and `exec` as
/// its command then its args, one argument per row; `env` and `configOptions` as key/value
/// rows). Starting options the agent's catalog knows are picks (`startingOptions`); the rest
/// stay key/value rows (`configOptions`, "Other options"). Converts to and from
/// `AcpAgentConfig` here, so the normalizing is under `swift test`, not in a view.
public struct AcpAgentDraft: Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var command: String
    public var args: AcpArgList
    public var env: AcpPairList
    public var cwd: String
    /// Where the agent runs. Switching to This Mac sets the bridge URL to This Mac's; switching
    /// to Elsewhere clears that URL (it would not reach this Mac from there) but keeps any other.
    public var workspace: AcpWorkspaceKind {
        didSet {
            guard workspace != oldValue else { return }
            let thisMacURL = AcpAgentConfig.defaultCallbackURL(for: .thisMac)
            switch workspace {
            case .thisMac: mcpCallbackURL = thisMacURL
            case .elsewhere:
                if mcpCallbackURL.trimmingCharacters(in: .whitespaces) == thisMacURL { mcpCallbackURL = "" }
            }
        }
    }
    /// The options the agent last advertised (`AcpOptionCatalogStore`); empty = never seen.
    public let catalog: [AcpConfigOption]
    /// Starting values for options in `catalog`, by id. A missing key = the agent's default.
    public var startingOptions: [String: String]
    /// Every other starting option, as typed rows.
    public var configOptions: AcpPairList
    /// Used only Elsewhere; on This Mac the config takes This Mac's URL.
    public var mcpCallbackURL: String
    /// Elsewhere only: the exec prefix, command then args. Empty = none.
    public var exec: AcpArgList

    public init(_ config: AcpAgentConfig, catalog: [AcpConfigOption] = []) {
        id = config.id
        name = config.name
        command = config.launch.command
        args = AcpArgList(config.launch.args)
        env = AcpPairList(config.env)
        cwd = config.cwd
        switch config.workspace {
        case .thisMac: workspace = .thisMac
        case .elsewhere: workspace = .elsewhere
        }
        self.catalog = catalog
        let known = Set(catalog.map(\.id))
        startingOptions = config.defaultConfigOptions.filter { known.contains($0.key) }
        configOptions = AcpPairList(config.defaultConfigOptions.filter { !known.contains($0.key) })
        mcpCallbackURL = config.mcpCallbackURL
        exec = AcpArgList(config.execRunnerCommand.map { [$0.command] + $0.args } ?? [])
    }

    /// A new agent's starting point: the config's defaults (This Mac), every field empty — the
    /// form's placeholders show the shape, and no one's path is pre-filled as a value.
    public static func new() -> AcpAgentDraft {
        AcpAgentDraft(AcpAgentConfig(name: "", launch: AcpCommand(command: ""), cwd: ""))
    }

    public var config: AcpAgentConfig {
        let execValues = exec.values
        let workspace: AcpWorkspace = switch self.workspace {
        case .thisMac: .thisMac
        case .elsewhere: .elsewhere(exec: execValues.first.map {
            AcpCommand(command: $0, args: Array(execValues.dropFirst()))
        })
        }
        let url: String = switch workspace {
        case .thisMac: AcpAgentConfig.defaultCallbackURL(for: .thisMac)
        case .elsewhere: mcpCallbackURL.trimmingCharacters(in: .whitespaces)
        }
        return AcpAgentConfig(
            id: id,
            name: name.trimmingCharacters(in: .whitespaces),
            launch: AcpCommand(command: command.trimmingCharacters(in: .whitespaces), args: args.values),
            env: env.map,
            cwd: cwd.trimmingCharacters(in: .whitespaces),
            workspace: workspace,
            defaultConfigOptions: configOptions.map.merging(startingOptions) { row, _ in row },
            mcpCallbackURL: url)
    }

    /// What the rows say that the config cannot: a key given twice (the config is a map, so it
    /// would silently keep one). Shown with the config's own errors; Save stays off while any.
    public var validationErrors: [String] {
        Self.duplicates("environment variable", env.duplicateKeys)
            + Self.duplicates("config option", configOptions.duplicateKeys
                + configOptions.pairs.map(\.key).filter { startingOptions[$0] != nil })
    }

    static func duplicates(_ what: String, _ keys: [String]) -> [String] {
        keys.map { "The \(what) \u{201C}\($0)\u{201D} is set more than once." }
    }
}
