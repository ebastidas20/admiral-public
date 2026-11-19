import Foundation

/// The four reactions an agent can leave on a group message instead of posting an
/// acknowledgement. Pure: the service logs them, the window draws `chips`.
public enum GroupReaction: String, CaseIterable, Sendable {
    case eyes = "👀"
    case up = "👍"
    case down = "👎"
    case done = "✅"

    /// What the tools and errors list.
    public static let allowed = allCases.map(\.rawValue).joined(separator: " ")

    /// The emoji itself, or a name an agent is likely to write for it (`:eyes:`, `thumbsup`,
    /// `+1`, `white_check_mark`). Anything else is nil.
    public static func parse(_ raw: String) -> GroupReaction? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 👍🏽-style skin tones and the emoji presentation selector are the same reaction.
        let base = String(trimmed.unicodeScalars.filter { !(0x1F3FB...0x1F3FF).contains($0.value) && $0.value != 0xFE0F })
        if let exact = GroupReaction(rawValue: base) { return exact }
        switch base.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ":")) {
        case "eyes", "look", "looking": return .eyes
        case "thumbsup", "thumbs_up", "thumbs-up", "+1", "up": return .up
        case "thumbsdown", "thumbs_down", "thumbs-down", "-1", "down": return .down
        case "check", "white_check_mark", "heavy_check_mark", "done": return .done
        default: return nil
        }
    }

    /// One emoji on one message and who left it, in the order they reacted.
    public struct Chip: Equatable, Sendable {
        public let emoji: String
        public let names: [String]
    }

    /// Message seq → its reactions, the emojis in `allCases` order. A member reacting twice with
    /// the same emoji counts once. `live` (member key → current callsign) names the reactors
    /// whose tabs are open by their current name.
    public static func chips(_ messages: [GroupMessage], live: [UUID: String] = [:]) -> [Int: [Chip]] {
        var byMessage: [Int: [String: [String]]] = [:]
        for message in messages {
            guard let target = message.reactionTo, let emoji = message.reaction else { continue }
            var names = byMessage[target, default: [:]][emoji, default: []]
            let name = message.authorName(live)
            if !names.contains(name) { names.append(name) }
            byMessage[target, default: [:]][emoji] = names
        }
        return byMessage.mapValues { emojis in
            allCases.compactMap { reaction in emojis[reaction.rawValue].map { Chip(emoji: reaction.rawValue, names: $0) } }
        }
    }

    /// The sentence a reaction's log entry carries, naming what it is on so a reader without
    /// the target in view still follows: `reacted 👍 to #5 (@api: "the total is right")`.
    static func sentence(_ reaction: GroupReaction, to target: GroupMessage) -> String {
        let who = target.isHuman ? "User" : "@\(target.name)"
        let flat = target.text.split(whereSeparator: \.isNewline).joined(separator: " ")
        let quote = flat.count > 40 ? String(flat.prefix(40)) + "…" : flat
        return "reacted \(reaction.rawValue) to #\(target.seq) (\(who): \"\(quote)\")"
    }
}
