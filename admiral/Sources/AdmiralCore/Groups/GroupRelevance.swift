import Foundation

/// Who an UNTAGGED group message is for. One model call reads the latest messages and the
/// member list and names the members the newest message is for; the message wakes exactly
/// those. The decisions live here, pure; the service feeds them (`GroupService.post`).
public enum GroupRelevance {
    /// How many of the latest messages the router reads.
    public static let contextMessages = 20

    /// The question put to the router about `message`, the newest in `log`. `candidates` are the
    /// callsigns that can be woken (never the sender).
    public static func prompt(group: String, candidates: [String], log: [GroupMessage],
                              names: [UUID: String]) -> String {
        let recent = log.suffix(contextMessages).map { GroupPrompt.numbered($0, names: names) }
        let members = candidates.map { "@" + GroupPrompt.inline($0) }.joined(separator: ", ")
        return """
        You route messages in a group chat named "\(GroupPrompt.inline(group))" between a user \
        and coding agents. Each agent is a member named by its @callsign.

        Members who can be woken: \(members)

        Conversation (oldest first, the last line is the new message):
        \(recent.joined(separator: "\n"))

        Which members does the new message need a reply or action from? Pick a member when the \
        message asks them something, answers or follows up on something they said, or touches \
        their work. Pick nobody when it needs nothing from anyone (thanks, a status note).
        Answer with JSON only, callsigns without @: {"members": ["callsign", ...]}
        """
    }

    /// The members named in a router's output: the `members` array of the first JSON object in
    /// it, matched case-insensitively against `candidates` (an `@` prefix is tolerated, unknown
    /// names are dropped). Nil when there is no such array, so a garbled answer is a failure,
    /// never "nobody".
    public static func parseMembers(_ output: String, candidates: [String]) -> [String]? {
        guard let open = output.firstIndex(of: "{"), let close = output.lastIndex(of: "}"), open < close,
              let data = String(output[open...close]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let names = object["members"] as? [Any] else { return nil }
        var picked: [String] = []
        for case let raw as String in names {
            let name = raw.hasPrefix("@") ? String(raw.dropFirst()) : raw
            if let match = candidates.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }),
               !picked.contains(match) { picked.append(match) }
        }
        return picked
    }

    /// The members the message wakes, in `candidates` order. `picked` is nil when the router
    /// failed. A user message always reaches someone: with no answer or an empty one it goes to
    /// every candidate. An agent message the router could not place, or placed with nobody,
    /// wakes nobody (it is still logged, and members read it with their next prompt).
    public static func select(candidates: [UUID], picked: Set<UUID>?, fromHuman: Bool) -> [UUID] {
        let chosen = candidates.filter { picked?.contains($0) ?? false }
        if chosen.isEmpty { return fromHuman ? candidates : [] }
        return chosen
    }
}
