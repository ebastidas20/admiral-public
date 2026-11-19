import Foundation

/// A named set of tabs sharing one message log. Members are tab ids (`AgentSession.id`), not
/// claude session ids: a group is a sidebar item and follows the tab, whatever claude is
/// resumed under.
public struct ChatGroup: Codable, Identifiable, Equatable, Sendable {
    public static let defaultBudget = 6

    public let id: UUID
    public var name: String
    public var members: [UUID]
    /// Agent messages allowed per human message before the group pauses.
    public var budgetLimit: Int
    /// Agent messages posted since the last human message (or Continue).
    public var spent: Int

    public init(id: UUID = UUID(), name: String, members: [UUID],
                budgetLimit: Int = ChatGroup.defaultBudget, spent: Int = 0) {
        self.id = id
        self.name = name
        self.members = members
        self.budgetLimit = budgetLimit
        self.spent = spent
    }

    /// Agents have used the budget: messages still log, nobody is woken.
    public var isPaused: Bool { spent >= budgetLimit }
}

/// One line of a group's log. The author's name and look are copied in when it is posted, so
/// history still reads right after the tab is closed; while the tab is open its current name
/// is shown instead (`authorName`), so a rename shows on every message at once.
public struct GroupMessage: Codable, Identifiable, Equatable, Sendable {
    public enum Author: Codable, Equatable, Sendable {
        case human
        case member(UUID)
    }

    /// Who the sender addressed: everyone, or only these members.
    public enum Target: Codable, Equatable, Sendable {
        case everyone
        case members([UUID])
    }

    /// 1-based position in the log. Cursors and `group_log(since:)` count in these.
    public var seq: Int
    public var ts: Date
    public var author: Author
    public var name: String
    public var colorHex: String?
    public var symbol: String?
    public var text: String
    public var target: Target
    /// Set on a reaction: the emoji (one of `GroupReaction`) and the `seq` it is on. A reaction
    /// is a log entry of its own, so cursors and the transcript copy treat it like any line, but
    /// it wakes nobody and spends no budget; `text` reads as a sentence for prompts and the log.
    public var reaction: String?
    public var reactionTo: Int?

    public var id: Int { seq }

    public init(seq: Int, ts: Date, author: Author, name: String, colorHex: String? = nil,
                symbol: String? = nil, text: String, target: Target,
                reaction: String? = nil, reactionTo: Int? = nil) {
        self.reaction = reaction
        self.reactionTo = reactionTo
        self.seq = seq
        self.ts = ts
        self.author = author
        self.name = name
        self.colorHex = colorHex
        self.symbol = symbol
        self.text = text
        self.target = target
    }

    public var isHuman: Bool { author == .human }
    public var isReaction: Bool { reactionTo != nil }

    /// The author's name as it reads now: the member's current callsign from `live` (member key
    /// → callsign) while its tab is open, else the name copied in when it was posted.
    public func authorName(_ live: [UUID: String]) -> String {
        if case .member(let id) = author, let current = live[id] { return current }
        return name
    }
}

public enum GroupError: Error, Equatable, CustomStringConvertible {
    case noSuchGroup(String)
    case nameTaken(String)
    case tooFewMembers
    case notAMember(String)
    case alreadyMember(String)
    case unknownMention(String, valid: [String])
    case emptyMessage
    case disabled
    case badReaction(String)
    case noSuchMessage(Int)
    case cannotReact(String)

    public var description: String {
        switch self {
        case .noSuchGroup(let ref): return "no group named or with id \"\(ref)\""
        case .nameTaken(let name): return "a group named \"\(name)\" already exists"
        case .tooFewMembers: return "a group needs at least 2 members; delete the group instead"
        case .notAMember(let who): return "\"\(who)\" is not a member of this group"
        case .alreadyMember(let who): return "\"\(who)\" is already a member"
        case .unknownMention(let name, let valid):
            return "no member \"\(name)\" in this group; members: \(valid.joined(separator: ", "))"
        case .emptyMessage: return "message is empty"
        case .disabled: return "groups are off (Settings → Experimental Features)"
        case .badReaction(let raw): return "\"\(raw)\" is not a reaction; use one of \(GroupReaction.allowed)"
        case .noSuchMessage(let seq): return "no message #\(seq) in this group (use the #id from the prompt or group_log)"
        case .cannotReact(let why): return why
        }
    }
}
