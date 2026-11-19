import Foundation
import SwiftUI
import AdmiralCore

/// What the group views read off the model: members as live tabs, who is busy, the unread dot.
extension AppModel {
    /// The group's members that are open tabs, in member order.
    func memberSessions(_ group: ChatGroup) -> [AgentSession] {
        group.members.compactMap { session(forMemberKey: $0) }
    }

    /// The tabs whose footprint the Footprint panel shows: the selected group's members, or the
    /// selected tab. The panel-gated refreshes (touched repos, their PRs, tickets) walk these,
    /// so a group's members stay current even though none of them is the selected tab.
    var footprintSessions: [AgentSession] {
        if let group = selectedGroup { return memberSessions(group) }
        return sessions.selectedSession.map { [$0] } ?? []
    }

    func busyMembers(_ group: ChatGroup) -> [AgentSession] {
        memberSessions(group).filter { $0.status == .busy }
    }

    /// Stop on the group composer: interrupt every busy member.
    func interruptGroup(_ group: ChatGroup) {
        for session in busyMembers(group) { interrupt(session) }
    }

    /// Lowercased callsign → that member's tab color, for coloring `@name` in the timeline.
    func mentionColors(_ group: ChatGroup) -> [String: Color] {
        var colors: [String: Color] = ["all": Theme.accent]
        for session in memberSessions(group) {
            colors[session.displayTitle.lowercased()] = session.avatarColorHex.flatMap(Color.init(hexString:)) ?? Theme.accent
        }
        return colors
    }

    /// Open (non-scratch) tabs that are not in the group — the members popover's "Add tab".
    func nonMemberTabs(_ group: ChatGroup) -> [AgentSession] {
        sessions.sessions.filter { !$0.scratch && !group.members.contains(memberKey(for: $0)) }
    }

    // MARK: - Members' questions

    /// The group's messages with its members' AskUserQuestion-mirror questions merged in, read
    /// from each open member tab's chat ledger (`GroupAsks`). A closed tab's questions drop out:
    /// there is no tab to type an answer into.
    func groupTimeline(_ group: ChatGroup) -> [GroupTimelineItem] {
        let base = sessions.supportDir
        var ledgers: [UUID: [ChatEvent]] = [:]
        for tab in memberSessions(group) {
            guard let sid = tab.claudeSessionID else { continue }
            ledgers[memberKey(for: tab)] = ChatLedger.read(base: base, session: sid)
        }
        return GroupAsks.timeline(group: group, messages: groupStore.messages(group.id), ledgers: ledgers)
    }

    /// The question card in the group window was answered: the answer is typed into the asking
    /// member's tab exactly as that tab's own card types it (`answerAsk`), and logged to the
    /// group as "User (to @member): …" for the others to read, waking nobody. Logged first, so
    /// the member's prompt hook already counts it as delivered when the typed answer arrives.
    func answerGroupAsk(_ ask: GroupAsk, answers: [String], in group: ChatGroup) {
        guard groupsEnabled, let tab = session(forMemberKey: ask.member) else { return }
        groupService.logAnswer(group: group.id.uuidString, to: ask.member,
                               text: AskAnswer.text(questions: ask.questions, answers: answers))
        objectWillChange.send()
        answerAsk(ask.questions, answers: answers, for: tab)
    }

    // MARK: - Unread

    func groupHasUnread(_ group: ChatGroup) -> Bool {
        guard selectedGroupID != group.id else { return false }
        return GroupSeenCursor.isUnread(groupStore.messages(group.id), seen: groupSeen.seen(group.id))
    }

    /// The group window is showing everything up to its last message.
    func markGroupSeen(_ id: UUID) {
        guard let last = groupStore.messages(id).last?.seq, last > groupSeen.seen(id) else { return }
        objectWillChange.send()
        groupSeen.markSeen(id, through: last)
    }
}
