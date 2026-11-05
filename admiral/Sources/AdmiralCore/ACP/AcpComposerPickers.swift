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

/// A prompt that is a slash command: `/name` (letters, digits, `-`, `_`, `:`) then optional
/// arguments. "/path/to/file is broken" is not one — its name would hold a "/".
public struct AcpSlashCommand: Equatable, Sendable {
    public var name: String
    public var args: String

    public init?(_ prompt: String) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("/") else { return nil }
        let body = text.dropFirst()
        let name = body.prefix { !$0.isWhitespace }
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || "-_:".contains($0) }) else { return nil }
        self.name = String(name)
        self.args = body.dropFirst(name.count).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The command as claude's own transcript records one (what Chat shows as a command line).
    public var transcriptText: String {
        "<command-name>/\(name)</command-name>\n<command-message>\(name)</command-message>\n"
            + "<command-args>\(args)</command-args>"
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

/// The composer's `@` menu over the agent's files (`SessionManager.acpFiles`): pure text logic,
/// no UI. The composer has no caret position to read, so the query follows the end of the text.
public enum FileMentionPicker {
    public static let limit = 50

    public struct Query: Equatable, Sendable {
        /// Character offset of the `@`.
        public let offset: Int
        /// The path typed after it (may be empty).
        public let partial: String

        public init(offset: Int, partial: String) {
            self.offset = offset
            self.partial = partial
        }
    }

    /// The text ends in `@` + path characters (anything but whitespace), and that `@` starts a word.
    public static func query(in text: String) -> Query? {
        let chars = Array(text)
        var i = chars.count
        while i > 0, !chars[i - 1].isWhitespace, chars[i - 1] != "@" { i -= 1 }
        guard i > 0, chars[i - 1] == "@", startsWord(chars, at: i - 1) else { return nil }
        return Query(offset: i - 1, partial: String(chars[i...]))
    }

    /// Basename-prefix matches first, then path-substring matches; path order within each;
    /// case-insensitive; at most `limit`.
    public static func candidates(_ partial: String, files: [String]) -> [String] {
        let p = partial.lowercased()
        guard !p.isEmpty else { return Array(files.prefix(limit)) }
        var prefix: [String] = [], inside: [String] = []
        for file in files {
            let lower = file.lowercased()
            if basename(lower).hasPrefix(p) {
                prefix.append(file)
            } else if lower.contains(p) {
                inside.append(file)
            }
            if prefix.count >= limit { break }
        }
        return Array((prefix + inside).prefix(limit))
    }

    /// Text with the query replaced by "@path ".
    public static func insert(_ path: String, into text: String, at query: Query) -> String {
        String(Array(text)[..<query.offset]) + "@" + path + " "
    }

    /// The `@path` tokens in `text` that are in `files` (dedup, in order) — what becomes
    /// resource_link blocks. A path may hold spaces, so each word-starting `@` takes the longest
    /// known path that follows it up to whitespace, punctuation or the end.
    public static func mentions(in text: String, files: Set<String>) -> [String] {
        let chars = Array(text)
        var out: [String] = []
        for (at, c) in chars.enumerated() where c == "@" && startsWord(chars, at: at) {
            let rest = String(chars[(at + 1)...])
            let match = files
                .filter { rest.hasPrefix($0) && endsToken(rest.dropFirst($0.count).first) }
                .max { $0.count < $1.count }
            if let match, !out.contains(match) { out.append(match) }
        }
        return out
    }

    public static func basename(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    private static func startsWord(_ chars: [Character], at i: Int) -> Bool {
        i == 0 || chars[i - 1].isWhitespace || "([{\"'".contains(chars[i - 1])
    }

    private static func endsToken(_ next: Character?) -> Bool {
        guard let next else { return true }
        return next.isWhitespace || ",.;:!?)]}\"'".contains(next)
    }
}
