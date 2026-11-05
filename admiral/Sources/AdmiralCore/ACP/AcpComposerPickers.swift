import Foundation

/// One slash command an ACP agent offers (`available_commands_update`). `name` has no leading "/".
public struct AcpCommandInfo: Hashable, Sendable, Codable {
    public var name: String
    public var description: String
    /// The `input.hint` shown after the name while the user types its arguments.
    public var hint: String?

    public init(name: String, description: String = "", hint: String? = nil) {
        self.name = name
        self.description = description
        self.hint = hint
    }
}

/// The composer's `/` menu: pure text logic, no UI.
public enum SlashCommandPicker {
    /// Open only while the WHOLE text is "/" + name characters (no whitespace yet): the partial after "/".
    public static func query(in text: String) -> String? {
        guard text.hasPrefix("/") else { return nil }
        let rest = text.dropFirst()
        return rest.contains(where: { $0.isWhitespace }) ? nil : String(rest)
    }

    /// Prefix matches first, then substring matches (name or description), agent order within each;
    /// case-insensitive.
    public static func candidates(_ partial: String, commands: [AcpCommandInfo]) -> [AcpCommandInfo] {
        let p = partial.lowercased()
        guard !p.isEmpty else { return commands }
        let prefix = commands.filter { $0.name.lowercased().hasPrefix(p) }
        let inside = commands.filter {
            !$0.name.lowercased().hasPrefix(p)
                && ($0.name.lowercased().contains(p) || $0.description.lowercased().contains(p))
        }
        return prefix + inside
    }

    /// "/name " — the args (if any) are typed next.
    public static func insert(_ command: AcpCommandInfo) -> String { "/\(command.name) " }
}
