import Foundation

extension AgentSession {
    /// The id that survives a relaunch: `id` is minted fresh every launch, `claudeSessionID` is
    /// what restore resumes (claude and bash tabs alike). Group membership, cursors, message
    /// authors and the sidebar order all key on this. The tab id is the fallback only for a
    /// session without a parsable persistent id (test arms).
    public var stableKey: UUID {
        claudeSessionID.flatMap { UUID(uuidString: $0) } ?? id
    }
}

/// One row of the sidebar's main list.
public enum SidebarItem: Hashable, Sendable, Identifiable {
    /// A tab, by its (per-launch) `AgentSession.id`.
    case session(UUID)
    case group(UUID)

    public var id: UUID {
        switch self { case .session(let id), .group(let id): return id }
    }
}

/// The sidebar's one ordered list of tabs and groups. Pure: the app hands in what it has and
/// gets the list back.
///
/// The sessions array (`SessionManager.sessions`, persisted by `OpenSessionsStore`) stays the
/// one authority on the order of tabs among themselves; the stored order only says where the
/// groups sit between them. So with no groups the list is exactly today's tab list, and the
/// two can never disagree about the tabs.
public enum SidebarOrder {
    private enum Slot { case session, group(UUID) }

    /// The main list: permanent tabs and (flag on) groups. Scratch tabs are never in it —
    /// they live in their own section and keyboard navigation never lands on them. Stored
    /// keys that match nothing are dropped; tabs and groups the stored order doesn't know are
    /// appended, tabs first.
    public static func items(stored: [UUID], sessions: [AgentSession], groups: [ChatGroup],
                             groupsEnabled: Bool) -> [SidebarItem] {
        let tabs = sessions.filter { !$0.scratch }
        let tabKeys = Set(tabs.map(\.stableKey))
        let groupIDs = groupsEnabled ? groups.map(\.id) : []
        let groupSet = Set(groupIDs)

        var slots: [Slot] = []
        var seen = Set<UUID>()
        for key in stored where seen.insert(key).inserted {
            if tabKeys.contains(key) { slots.append(.session) }
            else if groupSet.contains(key) { slots.append(.group(key)) }
        }
        let placed = slots.filter { if case .session = $0 { return true } else { return false } }.count
        slots += Array(repeating: .session, count: tabs.count - placed)
        slots += groupIDs.filter { !seen.contains($0) }.map(Slot.group)

        var next = tabs.makeIterator()
        return slots.compactMap { slot in
            switch slot {
            case .session: return next.next().map { .session($0.id) }
            case .group(let id): return .group(id)
            }
        }
    }

    /// What `sidebar-order.json` holds for `items`: tabs by their stable key.
    public static func keys(_ items: [SidebarItem], sessions: [AgentSession]) -> [UUID] {
        let byID = Dictionary(sessions.map { ($0.id, $0.stableKey) }, uniquingKeysWith: { a, _ in a })
        return items.compactMap { item in
            switch item {
            case .session(let id): return byID[id]
            case .group(let id): return id
            }
        }
    }

    // MARK: - Moves (drag, ⇧⌘↑/↓)

    /// `item` moved to just before `target` (drag-to-reorder). Unchanged when either is not
    /// in the list.
    public static func move(_ item: SidebarItem, before target: SidebarItem,
                            in items: [SidebarItem]) -> [SidebarItem] {
        guard item != target, let from = items.firstIndex(of: item), items.contains(target) else { return items }
        var result = items
        result.remove(at: from)
        result.insert(item, at: result.firstIndex(of: target) ?? result.endIndex)
        return result
    }

    /// `item` moved `delta` places (negative = up), clamped at the ends.
    public static func move(_ item: SidebarItem, by delta: Int, in items: [SidebarItem]) -> [SidebarItem] {
        guard let from = items.firstIndex(of: item) else { return items }
        let to = min(max(from + delta, 0), items.count - 1)
        guard to != from else { return items }
        var result = items
        result.remove(at: from)
        result.insert(item, at: to)
        return result
    }

    /// Brings the sessions array in line with `items` after `moved` moved: a moved tab goes
    /// just before the next tab below it in the list (or to the end). A moved group changes
    /// nothing in the array — tabs keep their relative order.
    @MainActor
    public static func syncSessions(_ manager: SessionManager, to items: [SidebarItem], moved: SidebarItem) {
        guard case .session(let id) = moved, let at = items.firstIndex(of: moved) else { return }
        let below = items[(at + 1)...].lazy.compactMap { item -> UUID? in
            if case .session(let next) = item { return next } else { return nil }
        }.first
        if let below { manager.move(id, before: below) }
        else { manager.move(id, by: manager.sessions.count) }
    }

    // MARK: - Selection (⌘1–9, ⌘↑/↓)

    /// ⌘↓: the index after `current`, wrapping; the first item when nothing in the list is
    /// selected. nil = empty list.
    public static func next(after current: Int?, count: Int) -> Int? {
        guard count > 0 else { return nil }
        return ((current ?? -1) + 1) % count
    }

    /// ⌘↑: the index before `current`, wrapping; the last item when nothing in the list is
    /// selected.
    public static func previous(before current: Int?, count: Int) -> Int? {
        guard count > 0 else { return nil }
        return ((current ?? 0) - 1 + count) % count
    }

    // MARK: - Search (⌘F)

    /// A group shows for a search that matches its name or any member's name.
    public static func groupMatches(_ group: ChatGroup, query: String, memberNames: [String]) -> Bool {
        query.isEmpty || group.name.localizedCaseInsensitiveContains(query)
            || memberNames.contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

/// `sidebar-order.json`: plain file beside the groups, like `GroupStore`.
@MainActor
public final class SidebarOrderStore {
    private let base: URL
    public private(set) var order: [UUID] = []

    public init(base: URL) {
        self.base = base
        if let data = try? Data(contentsOf: AdmiralPaths.sidebarOrderFile(base: base)),
           let decoded = try? JSONDecoder().decode([UUID].self, from: data) {
            order = decoded
        }
    }

    public func save(_ order: [UUID]) {
        self.order = order
        guard let data = try? JSONEncoder().encode(order) else { return }
        try? PrivateFile.write(data, to: AdmiralPaths.sidebarOrderFile(base: base))
    }
}

/// The tab ↔ member-key mapping for the group layer: members are `stableKey`s, while the
/// terminal to type into is whichever tab currently carries that key.
public enum GroupMembers {
    public static func peers(_ sessions: [AgentSession]) -> [GroupPeer] {
        // TODO(groups): pass `claudeSessionID` once GroupPeer carries it (another slice adds the field).
        // A tab's handle is the name it shows (a rename included), as everywhere on the bridge.
        sessions.map { GroupPeer(id: $0.stableKey, callsign: $0.displayTitle, status: $0.status,
                                 colorHex: $0.avatarColorHex, symbol: $0.avatarSymbol) }
    }

    public static func session(forKey key: UUID, in sessions: [AgentSession]) -> AgentSession? {
        sessions.first { $0.stableKey == key }
    }
}
