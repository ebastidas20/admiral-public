import Foundation

/// What the Chat view draws, folded from the ledger. Pure, so `swift test` pins it.
public struct ChatTranscript: Equatable, Sendable {
    public var items: [ChatItem]

    public init(items: [ChatItem] = []) { self.items = items }

    public static let empty = ChatTranscript()

    /// The question card still waiting on the user, if any.
    public var openAsk: (id: Int, questions: [AskQuestion])? {
        for item in items.reversed() {
            if case let .ask(id, questions, _, true) = item { return (id, questions) }
        }
        return nil
    }

    /// claude is blocked on the user: an unanswered question or permission prompt is last.
    public var isWaiting: Bool {
        switch items.last {
        case .ask(_, _, _, true)?, .needs(_, _, _, true)?: return true
        default: return false
        }
    }

    /// Timestamp of the latest prompt — the start of the current turn.
    public var lastPromptTS: String? {
        for item in items.reversed() { if case let .prompt(_, _, _, ts) = item { return ts } }
        return nil
    }
}

public enum ChatItem: Identifiable, Equatable, Sendable {
    case prompt(id: Int, text: String, source: String?, ts: String)
    /// What the agent said at a Stop. Once shown, a reply never changes — a later Stop in
    /// the same turn (a hook blocked the first) is simply another reply.
    case reply(id: Int, text: String, ts: String)
    case ask(id: Int, questions: [AskQuestion], ts: String, open: Bool)
    case needs(id: Int, text: String, ts: String, open: Bool)
    /// Something claude's harness told the session (a `<task-notification>`), shown as a
    /// plain line — it arrives as a prompt, but the user didn't write it.
    case notice(id: Int, text: String, ts: String)
    /// A tool call on an ACP tab (only when `ChatHistory` was asked for tools): it opens, opened
    /// at its `tool_use`'s line and time, and shows its result once one is read.
    case tool(id: Int, tool: ChatTool, ts: String)

    public var id: Int {
        switch self {
        case let .prompt(id, _, _, _), let .reply(id, _, _),
             let .ask(id, _, _, _), let .needs(id, _, _, _), let .notice(id, _, _), let .tool(id, _, _): return id
        }
    }

    public var ts: String {
        switch self {
        case let .prompt(_, _, _, ts), let .reply(_, _, ts),
             let .ask(_, _, ts, _), let .needs(_, _, ts, _), let .notice(_, _, ts), let .tool(_, _, ts): return ts
        }
    }
}

/// claude's `<task-notification>` — a background task ended — reduced to its message:
/// the summary, with the status when it isn't the ordinary "completed".
public enum TaskNotification {
    public static func message(_ prompt: String) -> String? {
        guard prompt.contains("<task-notification>") else { return nil }
        let summary = tag("summary", in: prompt) ?? "Background task finished"
        guard let status = tag("status", in: prompt), status != "completed" else { return summary }
        return "\(summary) (\(status))"
    }

    static func tag(_ name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)>"),
              let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex) else { return nil }
        let value = text[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

public enum ChatFolder {
    public static func fold(_ events: [ChatEvent]) -> ChatTranscript {
        var items: [ChatItem] = []
        for (offset, event) in events.enumerated() {
            let index = event.id ?? offset
            switch event.kind {
            case .prompt:
                let text = displayPrompt(event.text ?? "")
                guard !text.isEmpty else { continue }
                // Not the user's words, so not an answer to an open question either.
                if let notice = TaskNotification.message(text) {
                    items.append(.notice(id: index, text: notice, ts: event.ts))
                    continue
                }
                closeOpen(&items, asks: true)
                items.append(.prompt(id: index, text: text, source: event.source, ts: event.ts))
            case .reply:
                let text = (event.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                closeOpen(&items, asks: false)
                items.append(.reply(id: index, text: text, ts: event.ts))
            case .ask:
                guard let questions = event.questions, !questions.isEmpty else { continue }
                closeOpen(&items, asks: true)
                items.append(.ask(id: index, questions: questions, ts: event.ts, open: true))
            case .needs:
                closeOpen(&items, asks: false)
                items.append(.needs(id: index, text: event.text ?? "claude needs your permission",
                                    ts: event.ts, open: true))
            case .notice:
                guard let text = event.text, !text.isEmpty else { continue }
                items.append(.notice(id: index, text: text, ts: event.ts))
            case .resolved:
                closeOpen(&items, asks: true)
            case .tool:
                // Closes nothing: a call can run while its own permission card is still open.
                guard let tool = event.tool else { continue }
                items.append(.tool(id: index, tool: tool, ts: event.ts))
            }
        }
        return ChatTranscript(items: items)
    }

    /// A new prompt answers any open question; any later event means a permission prompt
    /// was dealt with. A reply alone does not answer a question: the mirror returns at once
    /// and the turn ends while the question is still waiting on the user.
    private static func closeOpen(_ items: inout [ChatItem], asks: Bool) {
        for i in items.indices {
            switch items[i] {
            case let .needs(id, text, ts, true):
                items[i] = .needs(id: id, text: text, ts: ts, open: false)
            case let .ask(id, questions, ts, true) where asks:
                items[i] = .ask(id: id, questions: questions, ts: ts, open: false)
            default:
                break
            }
        }
    }

    /// A pasted block reaches claude wrapped in `<pasted_content …>` tags; show the text.
    static func displayPrompt(_ raw: String) -> String {
        raw.replacingOccurrences(of: #"</?pasted_content[^>]*>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The text the chat card types into the session when the user answers a question: one line
/// per question, multi-select answers joined with ", " as claude's own tool joins them.
public enum AskAnswer {
    public static func text(questions: [AskQuestion], answers: [String]) -> String {
        var lines = ["My answers:"]
        for (index, question) in questions.enumerated() {
            let answer = index < answers.count ? answers[index] : ""
            lines.append("- \(question.question) → \(answer.isEmpty ? "(no answer)" : answer)")
        }
        return lines.joined(separator: "\n")
    }
}
