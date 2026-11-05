import Foundation

/// One line of a session's chat ledger (`<base>/chat/<session_id>.jsonl`).
///
/// The ledger is what the Chat view renders: the prompts, the agent's end-of-turn replies, and
/// the moments it needs the user — never tool calls or thinking. It is appended by the
/// `admiral-hook` helper (prompts, replies, permission prompts) and by the bridge's
/// `AskUserQuestion` mirror (questions), so it holds everything that happened whichever
/// surface the user was on.
public struct ChatEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// A prompt claude received (`UserPromptSubmit`), from any surface.
        case prompt
        /// What the agent said when a turn stopped (`Stop.last_assistant_message`).
        case reply
        /// Questions put to the user through the bridge's `AskUserQuestion` mirror.
        case ask
        /// claude is blocked on a permission prompt (`Notification`).
        case needs
        /// Something the harness said, not the user or the agent: hook feedback, an API
        /// error, a slash command and its output, an interrupt, a compaction. Read from the
        /// transcript, never written to the ledger.
        case notice
        /// The open question / permission cards were dealt with outside a prompt — an ACP
        /// agent's request answered, allowed or cancelled. Closes them; draws nothing.
        case resolved
        /// A tool call and, once it ended, its result — read from an ACP tab's transcript
        /// (`ChatHistory`'s `tools`), never written to the ledger. Carries `tool`.
        case tool
    }

    public var ts: String
    public var kind: Kind
    public var text: String?
    /// Who typed a prompt: nil for the user, else the Admiral feature that injected it.
    public var source: String?
    public var questions: [AskQuestion]?
    /// Stable identity for the rendered item, set by whoever read the event (its ledger line
    /// number; a negative transcript line number for history). Never written to disk.
    public var id: Int?
    /// The call a `.tool` event shows. Never written to disk.
    public var tool: ChatTool?

    enum CodingKeys: String, CodingKey { case ts, kind, text, source, questions }

    public init(ts: String, kind: Kind, text: String? = nil, source: String? = nil,
                questions: [AskQuestion]? = nil, id: Int? = nil, tool: ChatTool? = nil) {
        self.ts = ts
        self.kind = kind
        self.text = text
        self.source = source
        self.questions = questions
        self.id = id
        self.tool = tool
    }
}

/// One tool call as the ACP Chat draws it: what ran, how it ended, and what it produced.
public struct ChatTool: Hashable, Sendable {
    /// The call's id (the transcript's `tool_use` id).
    public var id: String
    /// The Claude tool name (`Bash`, `Edit`, …).
    public var name: String
    /// One line saying what the call did (the command, the file); the name when the input says nothing.
    public var title: String
    public var status: Status
    public var detail: Detail

    public enum Status: String, Sendable {
        case running, completed, failed
    }

    public enum Detail: Hashable, Sendable {
        case none
        /// What the call printed (a command's stdout, else its result text).
        case output(String)
        /// A file edit; `created` when the file is new.
        case diff(path: String, hunks: [LineDiff.Hunk], created: Bool)
    }

    public init(id: String, name: String, title: String, status: Status = .running, detail: Detail = .none) {
        self.id = id
        self.name = name
        self.title = title
        self.status = status
        self.detail = detail
    }

    /// The last `count` lines of streaming output (a final newline ends a line, it doesn't
    /// start an empty one) — what the Working row shows of a running command.
    public static func tail(_ text: String, lines count: Int) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if text.hasSuffix("\n") { lines.removeLast() }
        return lines.suffix(count).joined(separator: "\n")
    }
}

/// One question of an `AskUserQuestion` call — the built-in tool's input shape, as claude
/// sends it (probed on 2.1.278).
public struct AskQuestion: Codable, Equatable, Sendable {
    public var question: String
    public var header: String
    public var multiSelect: Bool
    public var options: [AskOption]

    public init(question: String, header: String, multiSelect: Bool = false, options: [AskOption]) {
        self.question = question
        self.header = header
        self.multiSelect = multiSelect
        self.options = options
    }

    enum CodingKeys: String, CodingKey { case question, header, multiSelect, options }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        question = try c.decode(String.self, forKey: .question)
        header = try c.decodeIfPresent(String.self, forKey: .header) ?? ""
        multiSelect = try c.decodeIfPresent(Bool.self, forKey: .multiSelect) ?? false
        options = try c.decodeIfPresent([AskOption].self, forKey: .options) ?? []
    }
}

public struct AskOption: Codable, Equatable, Sendable {
    public var label: String
    public var description: String?
    public var preview: String?

    public init(label: String, description: String? = nil, preview: String? = nil) {
        self.label = label
        self.description = description
        self.preview = preview
    }
}
