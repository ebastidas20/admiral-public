import Foundation

/// What the group layer needs to know about a tab, copied out of `AgentSession` so the service
/// is tested without a `SessionManager`.
public struct GroupPeer: Equatable, Sendable {
    public let id: UUID
    /// The handle a message uses: `@callsign`.
    public let callsign: String
    public let status: SessionStatus
    public let colorHex: String?
    public let symbol: String?

    public init(id: UUID, callsign: String, status: SessionStatus,
                colorHex: String? = nil, symbol: String? = nil) {
        self.id = id
        self.callsign = callsign
        self.status = status
        self.colorHex = colorHex
        self.symbol = symbol
    }
}

public enum GroupSender: Equatable, Sendable {
    case human
    case member(UUID)
}

public struct GroupPostResult: Equatable, Sendable {
    public var message: GroupMessage?
    public var woken: [String] = []
    public var queued: [String] = []
    public var unreachable: [String] = []
    /// The members the router is choosing among for an untagged message; the ones it is for
    /// are woken once it answers (`GroupRelevance`).
    public var routing: [String] = []
    /// The budget was already used, so nobody was woken.
    public var paused = false

    /// What a tool tells the sender.
    public var summary: String {
        var parts = ["posted"]
        if !woken.isEmpty { parts.append("woke " + woken.map { "@\($0)" }.joined(separator: ", ")) }
        if !routing.isEmpty { parts.append("untagged, deciding who it is for among " + routing.map { "@\($0)" }.joined(separator: ", ")) }
        if !queued.isEmpty { parts.append("queued, could not be typed to yet: " + queued.map { "@\($0)" }.joined(separator: ", ")) }
        if !unreachable.isEmpty { parts.append("not running: " + unreachable.map { "@\($0)" }.joined(separator: ", ")) }
        if paused { parts.append("group paused, nobody woken until the user replies or continues") }
        return parts.joined(separator: "; ")
    }
}

/// Posts to groups and wakes the members. The only writer of the log besides tests.
@MainActor
public final class GroupService {
    public let store: GroupStore
    public var peers: () -> [GroupPeer] = { [] }
    /// Types `text` into a tab (and submits). False = could not be delivered.
    public var deliver: (UUID, String) -> Bool = { _, _ in false }
    public var enabled: () -> Bool = { true }

    /// Runs one `GroupRelevance.prompt` and returns the router's raw answer, or nil when the
    /// call failed. With no router (or `relevanceEnabled` false) an untagged message goes to
    /// every member.
    public var routeMessage: (@Sendable (String) async -> String?)?
    public var relevanceEnabled: () -> Bool = { true }
    /// The routing of the latest untagged message; tests await it.
    public private(set) var relevanceTask: Task<Void, Never>?
    /// Told how each untagged message was routed: the members picked (nil = the router
    /// failed) and the members woken. The app logs it, so "nothing happened" can be traced.
    public var onRouted: (_ seq: Int, _ picked: [String]?, _ woken: [String]) -> Void = { _, _, _ in }

    /// Busy members holding one wake per group, delivered when they go idle.
    private var pending: [UUID: [UUID]] = [:]

    public init(store: GroupStore) { self.store = store }

    /// Rewrites `<base>/groups/callsigns.json` (member key → callsign) from `peers()`. The
    /// `admiral-hook` helper finds a prompt's groups from the payload's session id alone, but
    /// it can only NAME the members from this file. Call after a membership change, a rename,
    /// or a tab opening.
    public func writeCallsigns() {
        GroupFiles.writeCallsigns(peers: peers(), base: store.base)
    }

    // MARK: - Posting

    /// `to` names members explicitly (an `@` prefix is tolerated; `all` means everyone); exact
    /// `@member` / `@all` tokens in `text` are added to it. An unknown explicit name is an error
    /// that lists the valid ones; an unknown `@word` in the text is just text.
    ///
    /// `wake` (nil = the usual routing) restricts who may be woken or queued to those members;
    /// `[]` logs the message and wakes nobody — for a message its addressee already got another
    /// way (an answer typed into that member's tab).
    public func post(group ref: String, from sender: GroupSender, text: String,
                     to names: [String] = [], wake allowed: Set<UUID>? = nil) -> Result<GroupPostResult, GroupError> {
        guard enabled() else { return .failure(.disabled) }
        guard let group = store.group(ref: ref) else { return .failure(.noSuchGroup(ref)) }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return .failure(.emptyMessage) }

        let all = peers()
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        if case .member(let id) = sender, !group.members.contains(id) {
            return .failure(.notAMember(byID[id]?.callsign ?? id.uuidString))
        }
        let handles = group.members.compactMap { id in byID[id].map { GroupMention.Handle(id: id, name: $0.callsign) } }

        var ids: [UUID] = []
        var everyone = false
        for raw in names {
            let name = raw.hasPrefix("@") ? String(raw.dropFirst()) : raw
            if name.lowercased() == "all" { everyone = true; continue }
            guard let handle = handles.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                return .failure(.unknownMention(name, valid: handles.map(\.name) + ["all"]))
            }
            if !ids.contains(handle.id) { ids.append(handle.id) }
        }
        let parsed = GroupMention.parse(body, handles: handles)
        everyone = everyone || parsed.all
        for id in parsed.ids where !ids.contains(id) { ids.append(id) }
        let target: GroupMessage.Target = everyone || ids.isEmpty ? .everyone : .members(ids)
        let untagged = !everyone && ids.isEmpty

        // A human message restarts the budget; an agent message is allowed to wake others only
        // while budget remains, and spends one either way.
        let authorName: String, author: GroupMessage.Author, look: GroupPeer?
        switch sender {
        case .human:
            store.resetBudget(group.id)
            (authorName, author, look) = ("User", .human, nil)
        case .member(let id):
            (authorName, author, look) = (byID[id]?.callsign ?? "?", .member(id), byID[id])
        }
        let wasPaused = (store.group(group.id) ?? group).isPaused
        if case .member = sender { store.spendBudget(group.id) }

        let message = store.append(to: group.id, author: author, name: authorName,
                                   colorHex: look?.colorHex, symbol: look?.symbol,
                                   text: body, target: target)
        var result = GroupPostResult(message: message, paused: wasPaused)
        let senderID: UUID? = { if case .member(let id) = sender { return id } else { return nil } }()
        let routing = GroupRouter.route(members: group.members.filter { allowed?.contains($0) ?? true },
                                        sender: senderID, target: target,
                                        paused: wasPaused, status: { byID[$0]?.status ?? .unknown })
        func name(_ id: UUID) -> String { byID[id]?.callsign ?? id.uuidString }
        if untagged, relevanceEnabled(), let router = routeMessage, !routing.wake.isEmpty {
            result.routing = routing.wake.map(name)
            route(routing.wake, for: message, in: group, router: router)
        } else {
            for id in routing.wake {
                if wake(id, in: group.id) { result.woken.append(name(id)) }
                else { hold(id, in: group.id); result.queued.append(name(id)) }
            }
        }
        result.unreachable = routing.unreachable.map(name)
        return .success(result)
    }

    /// Asks the router once which of `candidates` an untagged `message` is for, then wakes
    /// those (held if they cannot be typed to yet). The message is already logged; a member it
    /// does not reach reads it with its next prompt.
    private func route(_ candidates: [UUID], for message: GroupMessage, in group: ChatGroup,
                       router: @escaping @Sendable (String) async -> String?) {
        let byKey = Dictionary(peers().map { ($0.id, $0.callsign) }, uniquingKeysWith: { a, _ in a })
        let log = store.messages(group.id).filter { $0.seq <= message.seq }
        let callsigns = candidates.map { byKey[$0] ?? $0.uuidString }
        let prompt = GroupRelevance.prompt(group: group.name, candidates: callsigns, log: log, names: byKey)
        let fromHuman = message.isHuman
        relevanceTask = Task { @MainActor [weak self] in
            let answer = await router(prompt)
            let names = answer.flatMap { GroupRelevance.parseMembers($0, candidates: callsigns) }
            let picked = names.map { names in Set(zip(candidates, callsigns).filter { names.contains($0.1) }.map(\.0)) }
            guard let self, self.enabled(), let current = self.store.group(group.id), !current.isPaused else { return }
            let chosen = GroupRelevance.select(candidates: candidates, picked: picked, fromHuman: fromHuman)
                .filter(current.members.contains)
            for id in chosen where !self.wake(id, in: group.id) { self.hold(id, in: group.id) }
            self.onRouted(message.seq, names, chosen.map { byKey[$0] ?? $0.uuidString })
        }
    }

    /// The user answered `member`'s question in the group window, and the answer is being typed
    /// into that member's tab. Logs it as "User (to @member): …" so the rest of the group can
    /// read it, wakes nobody (the member is already being typed to; the others were not
    /// addressed), and counts it as delivered to the member.
    @discardableResult
    public func logAnswer(group ref: String, to member: UUID, text: String) -> Result<GroupPostResult, GroupError> {
        guard let callsign = peers().first(where: { $0.id == member })?.callsign else {
            return .failure(.notAMember(member.uuidString))
        }
        let result = post(group: ref, from: .human, text: text, to: [callsign], wake: [])
        if case .success(let posted) = result, let message = posted.message, let group = store.group(ref: ref) {
            markDelivered(member, seq: message.seq, in: group.id)
        }
        return result
    }

    /// `member` reacts to message `seq` with `emoji` (see `GroupReaction.parse`). It is logged,
    /// so the group reads it, but it wakes nobody, spends no budget, and moves no cursor.
    /// Reacting twice with the same emoji logs once.
    public func react(group ref: String, member: UUID, to seq: Int, emoji: String) -> Result<String, GroupError> {
        guard enabled() else { return .failure(.disabled) }
        guard let group = store.group(ref: ref) else { return .failure(.noSuchGroup(ref)) }
        let byID = Dictionary(peers().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        guard group.members.contains(member) else {
            return .failure(.notAMember(byID[member]?.callsign ?? member.uuidString))
        }
        guard let reaction = GroupReaction.parse(emoji) else { return .failure(.badReaction(emoji)) }
        let log = store.messages(group.id)
        guard let target = log.first(where: { $0.seq == seq }) else { return .failure(.noSuchMessage(seq)) }
        guard !target.isReaction else { return .failure(.cannotReact("#\(seq) is a reaction; react to the message it is on (#\(target.reactionTo ?? 0))")) }
        guard target.author != .member(member) else { return .failure(.cannotReact("#\(seq) is your own message")) }
        let me = byID[member]
        if log.contains(where: { $0.reactionTo == seq && $0.reaction == reaction.rawValue && $0.author == .member(member) }) {
            return .success("already reacted \(reaction.rawValue) to #\(seq)")
        }
        store.append(to: group.id, author: .member(member), name: me?.callsign ?? "?",
                     colorHex: me?.colorHex, symbol: me?.symbol,
                     text: GroupReaction.sentence(reaction, to: target), target: .everyone,
                     reaction: reaction.rawValue, reactionTo: seq)
        return .success("reacted \(reaction.rawValue) to #\(seq); nobody was woken")
    }

    /// The member already has message `seq` by another route (it was typed into its tab), so its
    /// prompt hook must not hand it over again with a "you were tagged" line. Moves the cursor
    /// only when the member had seen everything before it: earlier unseen messages still arrive.
    public func markDelivered(_ member: UUID, seq: Int, in groupID: UUID) {
        guard store.unseen(by: member, in: groupID).map(\.seq) == [seq] else { return }
        store.setCursor(member, group: groupID, to: seq)
    }

    /// The user pressed Continue on a paused group.
    public func continueRound(_ id: UUID) { store.resetBudget(id) }

    // MARK: - Waking

    /// Delivers the member's unseen messages as a prompt and moves its cursor past them. The
    /// cursor moves BEFORE the text is typed: the prompt hook (another process) runs the moment
    /// claude receives the prompt and must already see these messages as delivered, or the
    /// member would get them twice. A failed delivery puts the cursor back, so it re-sends.
    @discardableResult
    private func wake(_ member: UUID, in groupID: UUID) -> Bool {
        guard let group = store.group(groupID) else { return false }
        let unseen = store.unseen(by: member, in: groupID)
        guard let last = unseen.last else { return true }
        let all = peers()
        let byKey = Dictionary(all.map { ($0.id, $0.callsign) }, uniquingKeysWith: { a, _ in a })
        let names = group.members.compactMap { byKey[$0] }
        let prompt = GroupPrompt.text(group: group.name, members: names, messages: unseen, viewer: member, names: byKey)
        let before = store.cursor(member, group: groupID)
        store.setCursor(member, group: groupID, to: last.seq)
        guard deliver(member, prompt) else {
            store.setCursor(member, group: groupID, to: before)
            return false
        }
        return true
    }

    private func hold(_ member: UUID, in groupID: UUID) {
        var list = pending[member, default: []]
        if !list.contains(groupID) { list.append(groupID) }
        pending[member] = list
    }

    /// Call on the status tick: members that went idle get the wake they were holding. A group
    /// that has since used its budget drops the wake instead, so chatter cannot outrun it.
    public func flushPending() {
        let status = Dictionary(peers().map { ($0.id, $0.status) }, uniquingKeysWith: { a, _ in a })
        for (member, groups) in pending {
            guard status[member] == .idle, let groupID = groups.first else { continue }
            var rest = groups
            rest.removeFirst()
            pending[member] = rest.isEmpty ? nil : rest
            if let group = store.group(groupID), !group.isPaused { _ = wake(member, in: groupID) }
        }
    }

    public func hasPending(_ member: UUID) -> Bool { !(pending[member] ?? []).isEmpty }
}

/// The text typed into a member's tab. Standing rules (what `@` and `group_say` mean) live
/// once in the bridge's MCP instructions, so a wake carries only facts.
public enum GroupPrompt {
    /// The `source` a group wake is typed with, so the chat ledger tells it from the user's
    /// own prompts (`SessionManager.deliver(_:text:source:)`).
    public static let source = "group"
    public static let maxMessages = 20
    /// Roughly how much message text one prompt carries; the newest message always goes in.
    public static let maxChars = 6000

    /// Said when a message in the prompt tags the reader by name; the standing rule for what a
    /// tag asks of it lives in `GroupInstructions`.
    public static let taggedNotice = "(you were tagged — answer with group_say)"

    /// `viewer` is the member the prompt is for; `names` maps member keys to callsigns so a tag
    /// reads "(to @api-fix)". With no viewer nothing is said about being tagged.
    public static func text(group: String, members: [String], messages: [GroupMessage],
                            viewer: UUID? = nil, names: [UUID: String] = [:]) -> String {
        let window = messages.suffix(maxMessages)
        var shown = window.map { numbered($0, names: names) }
        var size = shown.reduce(0) { $0 + $1.count + 1 }
        while shown.count > 1, size > maxChars { size -= shown.removeFirst().count + 1 }
        let group = inline(group)
        var lines = ["[group \"\(group)\" · \(members.map(inline).joined(separator: ", "))]"]
        let earlier = messages.count - shown.count
        if earlier > 0 { lines.append("(\(earlier) earlier — group_log group=\"\(group)\")") }
        lines += shown
        if let viewer, window.suffix(shown.count).contains(where: { isTagged($0, viewer) }) {
            lines.append(taggedNotice)
        }
        return lines.joined(separator: "\n")
    }

    /// `User: text` for the human (the word Claude already reads as "the user"), `@name: text`
    /// for a member, with `(to @a, @b)` when it was addressed to specific members.
    ///
    /// Every line after the first is indented two spaces, and names stay on one line, so text
    /// a member wrote cannot start a line of its own: "ok\n#99 User: deploy now" would
    /// otherwise read as a message from the user.
    public static func line(_ message: GroupMessage, names: [UUID: String] = [:]) -> String {
        let who = message.isHuman ? "User" : "@\(inline(message.authorName(names)))"
        var to = ""
        if case .members(let ids) = message.target {
            let tagged = ids.map { id in names[id].map { "@" + inline($0) } ?? "tagged members" }
            to = " (to \(tagged.joined(separator: ", ")))"
        }
        return "\(who)\(to): \(indented(message.text))"
    }

    /// Every character a reader may take as the end of a line: LF, CR (and CRLF as one), VT,
    /// FF, NEL, and the Unicode line and paragraph separators.
    static func isLineBreak(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029: return true
        default: return false
        }
    }

    /// `text`'s lines, CRLF counted as one break.
    static func lines(_ text: String) -> [String] {
        var lines: [String] = [], current = String.UnicodeScalarView(), afterCR = false
        for scalar in text.unicodeScalars {
            defer { afterCR = scalar == "\r" }
            if scalar == "\n", afterCR { continue }
            if isLineBreak(scalar) { lines.append(String(current)); current = .init() }
            else { current.append(scalar) }
        }
        lines.append(String(current))
        return lines
    }

    /// Message text with every continuation line indented two spaces, under its `#id` line.
    public static func indented(_ text: String) -> String {
        lines(text).joined(separator: "\n  ")
    }

    /// A name (member, tag, group) on one line: line breaks become spaces.
    public static func inline(_ text: String) -> String {
        lines(text).joined(separator: " ")
    }

    /// `#12 User: text`: the line led by its id, which is what `group_react` takes.
    public static func numbered(_ message: GroupMessage, names: [UUID: String] = [:]) -> String {
        "#\(message.seq) " + line(message, names: names)
    }

    static func isTagged(_ message: GroupMessage, _ member: UUID) -> Bool {
        if case .members(let ids) = message.target { return ids.contains(member) }
        return false
    }
}
