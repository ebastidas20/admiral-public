import Foundation
import AdmiralCore

/// The New Group sheet's request: which tabs start ticked, by member key
/// (`AgentSession.stableKey`, see `AppModel.memberKey(for:)`).
struct NewGroupRequest: Identifiable, Equatable {
    let id = UUID()
    var preselected: [UUID]
}

/// Group chat and the sidebar's unified item list. Everything here is
/// a no-op, an empty list or `.disabled` while `features.groups` is off. The ordering and
/// navigation logic is `SidebarOrder` in AdmiralCore; this only feeds it the app's state.
///
/// Group members are member KEYS (`AgentSession.stableKey`), which survive a relaunch; the tab
/// id does not. Every API below that names a member takes or returns a key.
extension AppModel {
    var groupsEnabled: Bool { config.features.groups }

    // MARK: - Wiring (init / flag change)

    func wireGroups() {
        groupService.peers = { [weak self] in GroupMembers.peers(self?.sessions.sessions ?? []) }
        groupService.deliver = { [weak self] key, text in
            guard let self, let tab = self.session(forMemberKey: key) else { return false }
            return self.sessions.deliver(tab.id, text: text, source: GroupPrompt.source)
        }
        groupService.enabled = { [weak self] in self?.groupsEnabled ?? false }
        let claude = Self.resolveClaude()
        groupService.routeMessage = { prompt in await GroupRelevanceScorer.route(prompt: prompt, claude: claude) }
        groupService.onRouted = { seq, picked, woken in
            GroupRelevanceScorer.log.notice(
                "group #\(seq, privacy: .public) routed: picked \(picked?.joined(separator: ",") ?? "<router failed>", privacy: .public); woke \(woken.joined(separator: ","), privacy: .public)")
        }
        groupService.relevanceEnabled = { [weak self] in self?.groupRelevanceEnabled ?? true }
        sessions.onDelete = { [weak self] session in self?.groupStore.removeSession(session.stableKey) }
        applyGroupsFlag()
    }

    /// The `group_*` tools exist only while the flag is on; turning it off also closes
    /// whatever group UI was showing.
    func applyGroupsFlag() {
        bridge.groups = groupsEnabled ? groupService : nil
        if !groupsEnabled {
            selectedGroupID = nil
            newGroupSheet = nil
        }
    }

    // MARK: - Member keys

    func memberKey(for session: AgentSession) -> UUID { session.stableKey }

    func session(forMemberKey key: UUID) -> AgentSession? {
        GroupMembers.session(forKey: key, in: sessions.sessions)
    }

    // MARK: - The unified list

    /// The sidebar's main list: permanent tabs and (flag on) groups, in display order. Scratch
    /// tabs are not in it. Also what ⌘1–9, ⌘↑/↓ and ⇧⌘↑/↓ walk.
    var sidebarItems: [SidebarItem] {
        SidebarOrder.items(stored: sidebarOrderStore.order, sessions: sessions.sessions,
                           groups: groupStore.groups, groupsEnabled: groupsEnabled)
    }

    /// The selected group, if it still exists and the flag is on.
    var selectedGroup: ChatGroup? {
        guard groupsEnabled, let id = selectedGroupID else { return nil }
        return groupStore.group(id)
    }

    var selectedItem: SidebarItem? {
        if let group = selectedGroup { return .group(group.id) }
        return sessions.selectedID.map(SidebarItem.session)
    }

    /// A tab: select it (and leave group view). A group: show it, leaving the tab selection
    /// as it was so closing the group returns there.
    func selectItem(_ item: SidebarItem) {
        switch item {
        case .session(let id): selectTerminal(id)
        case .group(let id): if groupsEnabled { selectedGroupID = id }
        }
    }

    private var currentIndex: Int? { selectedItem.flatMap { sidebarItems.firstIndex(of: $0) } }

    func selectByIndex(_ i: Int) {
        let items = sidebarItems
        guard items.indices.contains(i) else { return }
        selectItem(items[i])
    }

    func selectNext() {
        if let i = SidebarOrder.next(after: currentIndex, count: sidebarItems.count) { selectByIndex(i) }
    }

    func selectPrev() {
        if let i = SidebarOrder.previous(before: currentIndex, count: sidebarItems.count) { selectByIndex(i) }
    }

    /// ⇧⌘↑/⇧⌘↓ on the selected item. A selected scratch tab is not in the list, so it stays put.
    func moveSelectedUp() { if let item = selectedItem { moveItem(item, by: -1) } }
    func moveSelectedDown() { if let item = selectedItem { moveItem(item, by: 1) } }

    func moveItem(_ item: SidebarItem, by delta: Int) {
        let items = sidebarItems
        commitMove(item, from: items, to: SidebarOrder.move(item, by: delta, in: items))
    }

    /// Drag-to-reorder: `dragged` goes just before `target` (both `SidebarItem.id`s).
    func moveItem(_ dragged: UUID, before target: UUID) {
        let items = sidebarItems
        guard let item = items.first(where: { $0.id == dragged }),
              let over = items.first(where: { $0.id == target }) else { return }
        commitMove(item, from: items, to: SidebarOrder.move(item, before: over, in: items))
    }

    /// The tabs' own order (`SessionManager.move`, persisted by `OpenSessionsStore`) follows
    /// the list; the group positions go to `sidebar-order.json`, written only while the flag
    /// is on, so flag off behaves exactly as before.
    private func commitMove(_ moved: SidebarItem, from old: [SidebarItem], to new: [SidebarItem]) {
        guard new != old else { return }
        SidebarOrder.syncSessions(sessions, to: new, moved: moved)
        saveSidebarOrder(new)
    }

    private func saveSidebarOrder(_ items: [SidebarItem]) {
        guard groupsEnabled else { return }
        objectWillChange.send()
        sidebarOrderStore.save(SidebarOrder.keys(items, sessions: sessions.sessions))
    }

    // MARK: - Groups

    func requestNewGroup(preselected: [UUID] = []) {
        guard groupsEnabled else { return }
        newGroupSheet = NewGroupRequest(preselected: preselected)
    }

    /// `members` are member keys. On success the group is selected and placed last in the list.
    func createGroup(name: String, members: [UUID]) -> Result<ChatGroup, GroupError> {
        guard groupsEnabled else { return .failure(.disabled) }
        let result = groupStore.create(name: name, members: members)
        if case .success(let group) = result {
            saveSidebarOrder(sidebarItems)
            newGroupSheet = nil
            selectedGroupID = group.id
        }
        return result
    }

    func addGroupMember(_ member: UUID, to group: UUID) -> Result<ChatGroup, GroupError> {
        guard groupsEnabled else { return .failure(.disabled) }
        return groupStore.addMember(member, to: group)
    }

    func removeGroupMember(_ member: UUID, from group: UUID) -> Result<ChatGroup, GroupError> {
        guard groupsEnabled else { return .failure(.disabled) }
        return groupStore.removeMember(member, from: group)
    }

    func renameGroup(_ id: UUID, to name: String) -> Result<Void, GroupError> {
        guard groupsEnabled else { return .failure(.disabled) }
        return groupStore.rename(id, to: name)
    }

    /// Deletes the group, its log and cursors. Its member tabs are never touched.
    func deleteGroup(_ id: UUID) {
        guard groupsEnabled else { return }
        groupStore.delete(id)
        if selectedGroupID == id { selectedGroupID = nil }
    }

    /// The human posts in the group window.
    func postGroupMessage(group: UUID, text: String) -> Result<GroupPostResult, GroupError> {
        groupService.post(group: group.uuidString, from: .human, text: text)
    }

    /// "Continue" on a group paused after a long agent exchange.
    func continueGroup(_ id: UUID) {
        guard groupsEnabled else { return }
        groupService.continueRound(id)
    }
}
