import Foundation

/// Settings → Agents' form, as text: one field per editable value, lists one entry per line
/// (`args`, and `exec` as its command then its args), maps as `KEY=VALUE` lines. Converts to
/// and from `AcpAgentConfig` here, so the parsing is under `swift test`, not in a view.
public struct AcpAgentDraft: Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var command: String
    public var args: String
    public var env: String
    public var cwd: String
    public var defaultMode: String
    public var configOptions: String
    public var mcpCallbackURL: String
    /// Empty = use the exec derived from the launch command (`AcpAgentConfig.derivedExec`).
    public var exec: String

    public init(_ config: AcpAgentConfig) {
        id = config.id
        name = config.name
        command = config.launch.command
        args = config.launch.args.joined(separator: "\n")
        env = Self.lines(config.env)
        cwd = config.cwd
        defaultMode = config.defaultMode ?? ""
        configOptions = Self.lines(config.defaultConfigOptions)
        mcpCallbackURL = config.mcpCallbackURL
        exec = config.exec.map { ([$0.command] + $0.args).joined(separator: "\n") } ?? ""
    }

    /// A new agent's starting point: the config's defaults, `/workspace` as its folder.
    public static func new() -> AcpAgentDraft {
        AcpAgentDraft(AcpAgentConfig(name: "", launch: AcpCommand(command: ""), cwd: "/workspace"))
    }

    public var config: AcpAgentConfig {
        let execLines = Self.entries(exec)
        let mode = defaultMode.trimmingCharacters(in: .whitespaces)
        return AcpAgentConfig(
            id: id,
            name: name.trimmingCharacters(in: .whitespaces),
            launch: AcpCommand(command: command.trimmingCharacters(in: .whitespaces), args: Self.entries(args)),
            env: Self.pairs(env),
            cwd: cwd.trimmingCharacters(in: .whitespaces),
            defaultMode: mode.isEmpty ? nil : mode,
            defaultConfigOptions: Self.pairs(configOptions),
            mcpCallbackURL: mcpCallbackURL.trimmingCharacters(in: .whitespaces),
            exec: execLines.first.map { AcpCommand(command: $0, args: Array(execLines.dropFirst())) })
    }

    /// Non-empty lines, each trimmed of surrounding whitespace (an arg with inner spaces stays one arg).
    static func entries(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// `KEY=VALUE` lines; the value is everything after the first `=` (it may hold more).
    /// A line with no `=` or no key is dropped.
    static func pairs(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in entries(text) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            out[key] = String(line[line.index(after: eq)...])
        }
        return out
    }

    static func lines(_ map: [String: String]) -> String {
        map.keys.sorted().map { "\($0)=\(map[$0] ?? "")" }.joined(separator: "\n")
    }
}
