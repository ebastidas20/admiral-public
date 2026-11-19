import Foundation

/// Scans text with configurable regex patterns and returns unique ticket keys in first-seen order.
public enum TicketKeyFinder {
    /// Apply `patterns` to `text`. Invalid regexes are skipped (never fatal).
    public static func findKeys(in text: String, patterns: [String]) -> [String] {
        guard !text.isEmpty, !patterns.isEmpty else { return [] }
        var seen = Set<String>()
        var ordered: [String] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            regex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
                guard let match, let r = Range(match.range, in: text) else { return }
                let key = String(text[r])
                if seen.insert(key).inserted { ordered.append(key) }
            }
        }
        return ordered
    }

    /// The scannable text of a chat ledger: what the user typed and what the agent said —
    /// its replies and its questions (question, header, option labels and descriptions).
    ///
    /// Two kinds of prompt are neither. Claude delivers a finished background task or
    /// subagent as a `<task-notification>` prompt, and a research subagent's report cites
    /// every ticket in the code it read; and a prompt Admiral injected (`source` set) is
    /// Admiral talking. Their keys are the files' history, not the session's tickets.
    public static func scanText(of events: [ChatEvent]) -> String {
        var parts: [String] = []
        for event in events {
            if let text = event.text, !text.isEmpty, isConversation(event, text: text) {
                parts.append(text)
            }
            for q in event.questions ?? [] {
                parts.append(q.header)
                parts.append(q.question)
                for option in q.options {
                    parts.append(option.label)
                    if let d = option.description { parts.append(d) }
                }
            }
        }
        return parts.joined(separator: "\n")
    }

    private static func isConversation(_ event: ChatEvent, text: String) -> Bool {
        switch event.kind {
        case .reply, .ask: return true
        case .prompt:
            return event.source == nil
                && !text.drop(while: \.isWhitespace).hasPrefix("<task-notification>")
        case .needs, .notice, .resolved, .tool: return false
        }
    }
}
