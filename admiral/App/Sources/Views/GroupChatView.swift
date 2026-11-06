import SwiftUI
import AppKit
import AdmiralCore

/// A group's window: one shared timeline drawn with the tab chat's own pieces (`ReplyView`,
/// `PromptBubble`, `DayDivider`, the working capsule, the composer box), so the two read alike.
/// Members' messages carry the look they had when posted, so a renamed or closed tab's history
/// still reads right.
struct GroupChatView: View {
    @EnvironmentObject var model: AppModel
    let group: ChatGroup
    /// Probe only: the composer starts with this text (e.g. "… @" to show the picker).
    var initialText: String = ""
    /// Probe only: the members popover starts open showing this refusal.
    var membersRefusal: String? = nil

    @State private var position = ScrollPosition(edge: .bottom)
    @State private var isAtBottom = true
    @State private var showMembers = false

    /// The log plus the members' questions (from their chat ledgers), by time.
    private var timeline: [GroupTimelineItem] { model.groupTimeline(group) }
    private var busy: [AgentSession] { model.busyMembers(group) }

    var body: some View {
        let timeline = self.timeline
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if timeline.isEmpty { emptyState }
                    let dayBreaks = GroupAsks.dayBreaks(timeline)
                    let mentions = model.mentionColors(group)
                    // A message's avatar follows the tab's CURRENT look; the look stored with the
                    // message only stands in once that tab is closed.
                    let tabs = Dictionary(model.memberSessions(group).map { (model.memberKey(for: $0), $0) },
                                          uniquingKeysWith: { a, _ in a })
                    let live = tabs.mapValues(AvatarLook.init(session:))
                    let chips = GroupReaction.chips(model.groupStore.messages(group.id))
                    ForEach(timeline) { item in
                        if dayBreaks.contains(item.id) { DayDivider(ts: GroupTimeline.iso(item.ts)) }
                        switch item {
                        case .message(let message):
                            GroupMessageRow(message: message, mentions: mentions, live: message.liveLook(in: live),
                                            text: GroupTimeline.displayText(message, names: tabs.mapValues(\.callsign)),
                                            reactions: chips[message.seq] ?? [])
                        case .ask(let ask):
                            if let tab = tabs[ask.member] { GroupAskRow(ask: ask, group: group, tab: tab) }
                        }
                    }
                    if !busy.isEmpty { GroupWorkingRow(busy: busy) }
                    if group.isPaused { PausedPill { model.continueGroup(group.id) } }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
                .padding(.horizontal, 28)
            }
            .scrollPosition($position)
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.visibleRect.maxY >= geo.contentSize.height - 40
            } action: { _, atBottom in
                if isAtBottom != atBottom { isAtBottom = atBottom }
            }
            .onChange(of: timeline.count) { followTail(); model.markGroupSeen(group.id) }
            .onChange(of: busy.isEmpty) { followTail() }
            .onAppear {
                position.scrollTo(edge: .bottom)
                model.markGroupSeen(group.id)
                if membersRefusal != nil { showMembers = true }
            }
            .accessibilityIdentifier("group-content")

            GroupComposer(group: group, busy: !busy.isEmpty, initialText: initialText, onSend: jumpToBottom)
        }
        .paneBackground(Theme.contentBackground)
    }

    private var header: some View {
        HStack(spacing: 10) {
            AvatarStack(looks: model.memberSessions(group).map(AvatarLook.init(session:)), size: 20)
            Text(group.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primaryText)
                .lineLimit(1)
            if model.groupStore.isDegraded(group) {
                Text("fewer than 2 members").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 0)
            Button { showMembers.toggle() } label: {
                Label("Members", systemImage: "person.2").font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.secondaryText)
            .help("Members of \(group.name)")
            .accessibilityIdentifier("group-members")
            .popover(isPresented: $showMembers, arrowEdge: .bottom) {
                GroupMembersPopover(groupID: group.id, initialError: membersRefusal)
            }
        }
        // On the timeline's reading column, so the header lines up with the messages under it.
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .frame(height: 40)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nothing here yet.").font(.system(size: 14, weight: .medium))
            Text("Messages to and from \(group.name) show here. @name wakes one member, @all wakes everyone.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(.top, 30)
    }

    private func followTail() {
        guard isAtBottom else { return }
        withAnimation(.easeOut(duration: 0.15)) { position.scrollTo(edge: .bottom) }
    }

    private func jumpToBottom() {
        isAtBottom = true
        withAnimation(.easeOut(duration: 0.2)) { position.scrollTo(edge: .bottom) }
    }
}

extension GroupMessage {
    /// The author's live look, when the author is a member tab still open.
    func liveLook(in looks: [UUID: AvatarLook]) -> AvatarLook? {
        if case .member(let key) = author { return looks[key] }
        return nil
    }
}

/// An avatar's color and symbol, from a live tab or from a message's snapshot.
struct AvatarLook: Equatable {
    var colorHex: String?
    var symbol: String

    init(colorHex: String?, symbol: String?) {
        self.colorHex = colorHex
        self.symbol = symbol ?? AgentType.claudeCode.symbolName
    }

    init(session: AgentSession) {
        self.init(colorHex: session.avatarColorHex, symbol: session.avatarSymbolName)
    }

    func avatar(_ size: CGFloat) -> Avatar { Avatar(colorHex: colorHex, symbol: symbol, size: size) }
}

/// Overlapping avatars, each ringed in the pane color so the overlap reads.
struct AvatarStack: View {
    let looks: [AvatarLook]
    let size: CGFloat
    var ring: Color = Theme.contentBackground

    var body: some View {
        HStack(spacing: -(size * 0.25 + 4)) {
            ForEach(looks.indices, id: \.self) { i in
                looks[i].avatar(size)
                    .padding(2)
                    .background(RoundedRectangle(cornerRadius: (size + 4) * 0.28, style: .continuous).fill(ring))
            }
        }
    }
}

private struct GroupMessageRow: View, Equatable {
    let message: GroupMessage
    let mentions: [String: Color]
    /// The author tab's current look, nil once that tab is gone.
    let live: AvatarLook?
    /// The bubble's text: the message, led by any addressee it does not already tag.
    let text: String
    /// What members reacted with, drawn under the message.
    let reactions: [GroupReaction.Chip]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.message == rhs.message && lhs.mentions == rhs.mentions && lhs.live == rhs.live
            && lhs.text == rhs.text && lhs.reactions == rhs.reactions
    }

    @ViewBuilder private var bubble: some View {
        let ts = GroupTimeline.iso(message.ts)
        if message.isHuman {
            PromptBubble(text: text, source: nil, ts: ts, cwd: NSHomeDirectory(), mentions: mentions)
        } else {
            ReplyView(text: text, ts: ts,
                      avatar: (live ?? AvatarLook(colorHex: message.colorHex, symbol: message.symbol)).avatar(ChatMetrics.avatar),
                      name: message.name, cwd: NSHomeDirectory(), mentions: mentions,
                      windowTitle: message.name)
        }
    }

    @ViewBuilder var body: some View {
        if reactions.isEmpty {
            bubble
        } else {
            withReactions
        }
    }

    private var withReactions: some View {
        VStack(alignment: message.isHuman ? .trailing : .leading, spacing: 5) {
            bubble
            HStack(spacing: 6) {
                ForEach(reactions, id: \.emoji) { chip in
                    HStack(spacing: 4) {
                        Text(chip.emoji).font(.system(size: 12))
                        Text(chip.names.joined(separator: ", "))
                            .font(.system(size: 11)).foregroundStyle(Theme.secondaryText).lineLimit(1)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Rectangle().fill(Theme.chipBackground))
                    .help(chip.names.map { "@\($0)" }.joined(separator: ", ") + " reacted " + chip.emoji)
                    .accessibilityIdentifier("group-reaction")
                }
            }
            .padding(.leading, message.isHuman ? 0 : ChatMetrics.avatar + 10)
        }
        .frame(maxWidth: .infinity, alignment: message.isHuman ? .trailing : .leading)
    }
}

/// A member's question, as a message from that member: its avatar, name and time, then the
/// tab's own question card. Answering here types into that member's tab exactly as its card
/// would (`AppModel.answerGroupAsk`); once answered, from either place, it folds to the summary.
private struct GroupAskRow: View {
    @EnvironmentObject var model: AppModel
    let ask: GroupAsk
    let group: ChatGroup
    let tab: AgentSession

    var body: some View {
        let ts = GroupTimeline.iso(ask.ts)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                AvatarLook(session: tab).avatar(ChatMetrics.avatar)
                Text(tab.callsign).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                Text(ChatTime.short(ts)).font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                    .help(ChatTime.full(ts))
                    .padding(.leading, -4)
                Spacer(minLength: 0)
            }
            if ask.open {
                AskCard(questions: ask.questions) { model.answerGroupAsk(ask, answers: $0, in: group) }
            } else {
                AskSummary(questions: ask.questions)
            }
        }
        .accessibilityIdentifier(ask.open ? "group-ask-open" : "group-ask-answered")
    }
}

/// ONE capsule for the whole group: the busy members' avatars, the pulse, a single word that
/// changes every few seconds (`GroupWorkingWords`), and how long they've been at it.
struct GroupWorkingRow: View {
    let busy: [AgentSession]
    @State private var since = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            AvatarStack(looks: busy.map(AvatarLook.init(session:)), size: ChatMetrics.avatar)
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let elapsed = context.date.timeIntervalSince(since)
                let index = GroupWorkingWords.index(elapsed: elapsed)
                WorkingCapsule(elapsed: GroupWorkingWords.elapsedLabel(Int(elapsed))) {
                    ZStack(alignment: .leading) {
                        Text(GroupWorkingWords.words[index] + "…")
                            .font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
                            .id(index)
                            .transition(.opacity)
                    }
                    .frame(minWidth: 88, alignment: .leading)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: index)
                }
            }
            .help(busy.map(\.callsign).joined(separator: ", ") + " working")
            Spacer(minLength: 0)
        }
        .accessibilityIdentifier("group-working")
    }
}

/// The budget ran out: agents' messages still log but wake nobody until Continue (or a new
/// message from the human).
struct PausedPill: View {
    let onContinue: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text("Agents paused after a long exchange")
                .font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
            Button(action: onContinue) {
                Text("Continue").font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .background(Rectangle().fill(Theme.accent))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("group-continue")
        }
        .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 5)
        .background(Rectangle().fill(Theme.chipBackground))
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
    }
}

// MARK: - Composer

/// The tab composer's box and keys (Enter sends, ⇧/⌥-Enter newline, Stop while members work),
/// without attachments, plus the `@` picker.
struct GroupComposer: View {
    @EnvironmentObject var model: AppModel
    let group: ChatGroup
    let busy: Bool
    var initialText: String = ""
    var onSend: () -> Void = {}

    @State private var text = ""
    @State private var error: String?
    @State private var selection = 0
    /// The `@` (by offset) whose picker Esc closed; it stays closed until another `@`.
    @State private var dismissedAt: Int?
    @FocusState private var focused: Bool

    private var hasContent: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var query: GroupMentionPicker.Query? {
        guard let q = GroupMentionPicker.query(in: text), q.offset != dismissedAt else { return nil }
        return q
    }

    private var members: [AgentSession] { model.memberSessions(group) }

    private var candidates: [GroupMentionPicker.Candidate] {
        guard let query else { return [] }
        return GroupMentionPicker.candidates(query.partial,
                                             members: members.map { .init(name: $0.callsign, id: $0.id) })
    }

    private var pickerOpen: Bool { !candidates.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Message \(group.name) — @ to mention a member")
                            .font(.system(size: 14)).foregroundStyle(Theme.secondaryText)
                            .padding(.top, 1).padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $text)
                        .font(.system(size: 14))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 22, maxHeight: 160)
                        .fixedSize(horizontal: false, vertical: true)
                        .focused($focused)
                        .onKeyPress(.return, phases: .down) { press in
                            if pickerOpen { accept(); return .handled }
                            if press.modifiers.contains(.shift) || press.modifiers.contains(.option) { return .ignored }
                            send()
                            return .handled
                        }
                        .onKeyPress(.tab) { pickerOpen ? { accept(); return .handled }() : .ignored }
                        .onKeyPress(.upArrow) { moveSelection(-1) }
                        .onKeyPress(.downArrow) { moveSelection(1) }
                        .onKeyPress(.escape) {
                            if let query, pickerOpen { dismissedAt = query.offset; return .handled }
                            guard text.isEmpty, busy else { return .ignored }
                            model.interruptGroup(group)
                            return .handled
                        }
                        .accessibilityIdentifier("group-input")
                }
                HStack(spacing: 6) {
                    ComposerHint(isWorking: busy)
                    Spacer()
                    ComposerSendButton(stop: busy && !hasContent, hasContent: hasContent, isWorking: busy,
                                       onStop: { model.interruptGroup(group) }, onSend: send)
                }
            }
            .composerBox(focused: focused || pickerOpen)
            // Anchored above the box: a zero-height strip on its top edge, the list hanging up from it.
            .overlay(alignment: .top) {
                if pickerOpen {
                    Color.clear.frame(maxWidth: .infinity).frame(height: 0)
                        .overlay(alignment: .bottom) {
                            MentionPickerList(candidates: candidates, members: members,
                                              selection: min(selection, candidates.count - 1)) { accept($0) }
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.bottom, 6)
                        }
                }
            }
            if let error {
                Text(error)
                    .font(.system(size: 11.5)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6)
                    .accessibilityIdentifier("group-send-error")
            }
        }
        .composerColumn()
        .onAppear {
            if text.isEmpty { text = initialText }
            focused = true
        }
        .onChange(of: query?.partial) { selection = 0 }
        .onChange(of: text) { if error != nil, text.isEmpty { error = nil } }
        .onChange(of: group.id) { text = ""; error = nil; focused = true }
    }

    private func moveSelection(_ delta: Int) -> KeyPress.Result {
        guard pickerOpen else { return .ignored }
        selection = GroupMentionPicker.move(min(selection, candidates.count - 1), by: delta, count: candidates.count)
        return .handled
    }

    private func accept(_ index: Int? = nil) {
        guard let query, pickerOpen else { return }
        let i = min(index ?? selection, candidates.count - 1)
        text = GroupMentionPicker.insert(candidates[i].name, into: text, at: query)
        selection = 0
    }

    private func send() {
        guard hasContent else { return }
        switch model.postGroupMessage(group: group.id, text: text) {
        case .success:
            text = ""
            error = nil
            dismissedAt = nil
            onSend()
        case .failure(let refusal):
            error = refusal.description   // the text stays, so it can be fixed and resent
        }
    }
}

/// The `@` picker: the group's members (avatar, callsign, status) and `all`.
private struct MentionPickerList: View {
    let candidates: [GroupMentionPicker.Candidate]
    let members: [AgentSession]
    let selection: Int
    let pick: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(candidates.indices, id: \.self) { i in
                if candidates[i].isAll, i > 0 { Divider().padding(.vertical, 4) }
                row(i)
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.bubbleBackground))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.bubbleBorder))
        .shadow(color: .black.opacity(0.2), radius: 15, y: 8)
        .accessibilityIdentifier("group-mention-picker")
    }

    private func row(_ i: Int) -> some View {
        let candidate = candidates[i]
        let session = members.first { $0.id == candidate.id }
        return HStack(spacing: 10) {
            if let session {
                Avatar(session: session, size: 20)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 20 * 0.28, style: .continuous).fill(Theme.accent)
                    Text("@").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                }
                .frame(width: 20, height: 20)
            }
            Text(candidate.name).font(.system(size: 13)).foregroundStyle(Theme.primaryText)
            Spacer(minLength: 8)
            Text(session.map { MemberStatus.label($0.status) } ?? "everyone in the group")
                .font(.system(size: 11.5)).foregroundStyle(Theme.secondaryText)
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(i == selection ? Theme.rowSelection : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { pick(i) }
    }
}

enum MemberStatus {
    static func label(_ status: SessionStatus) -> String {
        switch status {
        case .busy: return "Working"
        case .idle: return "Idle"
        case .shell: return "Not running"
        case .unknown: return "Starting"
        }
    }
}

// MARK: - Members

/// The group's members with a remove button each, and "Add tab" for the open tabs not in it.
/// A removal the store refuses (it would leave fewer than 2) shows the store's own message.
struct GroupMembersPopover: View {
    @EnvironmentObject var model: AppModel
    let groupID: UUID
    var initialError: String? = nil
    @State private var error: String?

    var body: some View {
        if let group = model.groupStore.group(groupID) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Members").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primaryText)
                VStack(spacing: 2) {
                    ForEach(group.members, id: \.self) { key in memberRow(key, in: group) }
                }
                Divider()
                let candidates = model.nonMemberTabs(group)
                Menu {
                    ForEach(candidates) { tab in
                        Button(tab.displayTitle) { apply(model.addGroupMember(model.memberKey(for: tab), to: group.id)) }
                    }
                } label: {
                    Label("Add tab", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(candidates.isEmpty)
                .accessibilityIdentifier("group-add-member")
                if let error {
                    Text(error)
                        .font(.system(size: 11.5)).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("group-members-error")
                }
            }
            .padding(14)
            .frame(width: 280, alignment: .leading)
            .onAppear { if error == nil { error = initialError } }
        }
    }

    private func memberRow(_ key: UUID, in group: ChatGroup) -> some View {
        let session = model.session(forMemberKey: key)
        return HStack(spacing: 9) {
            if let session {
                Avatar(session: session, size: 20)
            } else {
                RoundedRectangle(cornerRadius: 20 * 0.28, style: .continuous).fill(Theme.pendingGray)
                    .frame(width: 20, height: 20)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(session?.callsign ?? "Closed tab").font(.system(size: 13)).foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                Text(session.map { MemberStatus.label($0.status) } ?? "not open")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 0)
            Button { apply(model.removeGroupMember(key, from: group.id)) } label: {
                Image(systemName: "minus.circle").font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.secondaryText)
            .help("Remove from \(group.name)")
        }
        .padding(.vertical, 3)
    }

    private func apply(_ result: Result<ChatGroup, GroupError>) {
        switch result {
        case .success: error = nil
        case .failure(let refusal): error = refusal.description
        }
    }
}
