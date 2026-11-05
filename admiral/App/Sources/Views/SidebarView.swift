import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AdmiralCore

/// Live drag-to-reorder for a sidebar list: as the dragged item passes over a row, it's
/// moved to just before that row.
///
/// With groups on, a TAB held over the middle band of another TAB row (`SidebarDropZone`)
/// does not reorder: the row lights up, and dropping there proposes a new group of the two.
/// `group` nil (flag off, or a list without groups) keeps the plain reorder.
struct ReorderDropDelegate: DropDelegate {
    let item: UUID
    @Binding var dragging: UUID?
    let move: (_ dragged: UUID, _ before: UUID) -> Void
    var group: GroupDrop? = nil

    struct GroupDrop {
        @Binding var target: UUID?
        let rowHeight: CGFloat
        let isTab: (UUID) -> Bool
        let propose: (_ dragged: UUID, _ onto: UUID) -> Void
    }

    private func zone(_ info: DropInfo) -> SidebarDropZone {
        guard let group, let d = dragging else { return .reorder }
        return SidebarDropZone.zone(y: info.location.y, height: group.rowHeight, draggedIsTab: group.isTab(d),
                                    targetIsTab: group.isTab(item), groupsEnabled: true)
    }

    private func track(_ info: DropInfo) {
        guard let d = dragging, d != item else { return }
        if zone(info) == .group, let group {
            if group.target != item { group.target = item }
        } else {
            if let group, group.target == item { group.target = nil }
            move(d, item)
        }
    }

    func dropEntered(info: DropInfo) { track(info) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        if group != nil { track(info) }
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) {
        if let group, group.target == item { group.target = nil }
    }
    func performDrop(info: DropInfo) -> Bool {
        if let group {
            if group.target == item, let d = dragging, d != item { group.propose(d, item) }
            group.target = nil
        }
        dragging = nil
        return true
    }
}

/// The always-visible left bar: a search field, a column of session buttons, and the
/// New Session / New Bash actions pinned at the bottom. Collapsed shows icons only;
/// expanded shows search + icons + names. Never hidden.
struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    @State private var search = ""
    @State private var pendingSearchFocus = false
    @FocusState private var searchFocused: Bool
    @State private var pendingDelete: AgentSession?
    @State private var pendingGroupDelete: ChatGroup?
    /// The item (tab or group) being dragged, by `SidebarItem.id`.
    @State private var dragging: UUID?
    /// The tab row a dragged tab is held over the middle of (drop = new group of the two).
    @State private var groupDropTarget: UUID?
    @State private var renamingGroup: ChatGroup?

    private var collapsed: Bool { model.sidebarCollapsed }

    /// The main list (`AppModel.sidebarItems`), narrowed by the search field: a tab by its
    /// title or branch, a group by its name or a member's callsign.
    private var filteredItems: [SidebarItem] {
        let items = model.sidebarItems
        guard !search.isEmpty else { return items }
        return items.filter { item in
            switch item {
            case .session(let id):
                guard let s = session(id) else { return false }
                return s.displayTitle.localizedCaseInsensitiveContains(search)
                    || (s.gitBranch?.localizedCaseInsensitiveContains(search) ?? false)
            case .group(let id):
                guard let g = model.groupStore.group(id) else { return false }
                let names = g.members.compactMap { model.session(forMemberKey: $0)?.callsign }
                return SidebarOrder.groupMatches(g, query: search, memberNames: names)
            }
        }
    }

    private func session(_ id: UUID) -> AgentSession? {
        model.sessions.sessions.first { $0.id == id }
    }

    @ViewBuilder
    private func row(_ item: SidebarItem) -> some View {
        switch item {
        case .session(let id):
            if let session = session(id) {
                SessionRow(
                    session: session, collapsed: collapsed,
                    selected: model.selectedItem == item,
                    onSelect: { model.selectItem(item) },
                    onRequestDelete: { pendingDelete = session }
                )
            }
        case .group(let id):
            if let group = model.groupStore.group(id) {
                GroupRow(
                    group: group, collapsed: collapsed,
                    selected: model.selectedItem == item,
                    onSelect: { model.selectItem(item) },
                    onRename: { renamingGroup = group },
                    onRequestDelete: { pendingGroupDelete = group }
                )
            }
        }
    }

    /// Tab-on-tab "make a group" for the drop delegate; nil while groups are off.
    private var groupDrop: ReorderDropDelegate.GroupDrop? {
        guard model.groupsEnabled else { return nil }
        let tabs = Set(model.sessions.sessions.map(\.id))
        return .init(target: $groupDropTarget, rowHeight: SidebarMetrics.row,
                     isTab: { tabs.contains($0) },
                     propose: { dragged, onto in
                         let keys = [dragged, onto].compactMap { id in session(id).map(model.memberKey(for:)) }
                         model.requestNewGroup(preselected: keys)
                     })
    }
    /// The pinned bottom actions, in the order `GroupUIGate.footer` gives.
    @ViewBuilder
    private func footerRow(_ action: GroupUIGate.FooterAction) -> some View {
        switch action {
        case .newClaudeCode:
            ActionButton(icon: "plus", label: "New Session",
                         shortcut: Shortcuts.newClaudeCode, collapsed: collapsed,
                         id: "commission-button-sidebar") { model.requestCommission() }
        case .newBash:
            ActionButton(icon: "terminal", label: "New Bash",
                         shortcut: Shortcuts.newBash, collapsed: collapsed,
                         id: "new-bash-button") { model.requestBash() }
        case .newGroup:
            ActionButton(icon: "square.grid.2x2", label: "New Group…", collapsed: collapsed,
                         id: "new-group-button") { model.requestNewGroup() }
        case .apiServer:
            ServerToggleRow(collapsed: collapsed)
        case .schedules:
            SchedulesRow(collapsed: collapsed)
        case .settings:
            ActionButton(icon: "gearshape", label: "Settings",
                         shortcut: Shortcuts.settings, collapsed: collapsed,
                         id: "settings-open") { model.openSettings() }
        }
    }

    /// Scratch tabs — the mini section pinned under the main list.
    private var scratchSessions: [AgentSession] {
        model.sessions.sessions.filter(\.scratch)
    }

    var body: some View {
        VStack(spacing: 0) {
            if collapsed {
                // Search icon in the rail: expand the bar and focus the field.
                Button {
                    pendingSearchFocus = true
                    model.sidebarCollapsed = false
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(maxWidth: .infinity)
                        .frame(height: SidebarMetrics.row)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Search (\(Shortcuts.search))")
                .padding(.horizontal, 8).padding(.top, 8)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                    TextField("Search…", text: $search)
                        .textFieldStyle(.plain).font(.system(size: 13))
                        .focused($searchFocused)
                }
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(Rectangle().fill(Theme.chipBackground))
                .padding(.horizontal, 8).padding(.top, 8)
                .onAppear {
                    if pendingSearchFocus {
                        pendingSearchFocus = false
                        DispatchQueue.main.async { searchFocused = true }
                    }
                }
            }
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(filteredItems) { item in
                        row(item)
                            .opacity(dragging == item.id ? 0.4 : 1)
                            .overlay {
                                if groupDropTarget == item.id {
                                    Rectangle()
                                        .fill(Theme.accent.opacity(0.18))
                                        .overlay(Rectangle()
                                            .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                                        .allowsHitTesting(false)
                                }
                            }
                            .onDrag { dragging = item.id; return NSItemProvider(object: item.id.uuidString as NSString) }
                            .onDrop(of: [.text], delegate: ReorderDropDelegate(item: item.id, dragging: $dragging,
                                                                               move: { model.moveItem($0, before: $1) },
                                                                               group: groupDrop))
                    }
                }
                .padding(.vertical, 8)  // no side inset: the selected row spans the whole bar
            }
            .sheet(item: $pendingGroupDelete) { group in
                ConfirmDeleteSheet(
                    title: "Delete group “\(group.name)”?",
                    message: "Its tabs stay.",
                    onConfirm: { model.deleteGroup(group.id) }
                )
            }
            .sheet(item: $renamingGroup) { group in RenameGroupSheet(group: group) }
            if !scratchSessions.isEmpty {
                Divider()
                VStack(spacing: 1) {
                    ForEach(scratchSessions) { session in
                        MiniSessionRow(
                            session: session, collapsed: collapsed,
                            selected: model.sessions.selectedID == session.id,
                            onSelect: { model.selectTerminal(session.id) },
                            onPromote: { model.requestPromote(session.id) },
                            onRequestDelete: { pendingDelete = session }
                        )
                    }
                }
                .padding(.vertical, 4)
            }
            Divider()
            VStack(spacing: 2) {
                ForEach(GroupUIGate.footer(groupsEnabled: model.groupsEnabled,
                                           apiServer: model.config.features.apiServer), id: \.self) { action in
                    footerRow(action)
                }
            }
            .padding(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.sidebarBackground)
        // Custom themed confirm — keyboard-first (Return deletes, Esc cancels) regardless
        // of Full Keyboard Access, and styled to match the app rather than a system alert.
        .sheet(item: $pendingDelete) { session in
            ConfirmDeleteSheet(
                title: "Delete “\(session.displayTitle)”?",
                message: "This ends “\(session.displayTitle)” and removes it from Admiral. "
                    + "It won't be restored next launch.",
                onConfirm: { model.sessions.delete(session.id) }
            )
        }
        .sheet(item: $model.promotingSession) { session in
            PromoteTabSheet(session: session)
        }
        // ⌘F: expand + focus the search field.
        .onChange(of: model.searchFocusToken) {
            DispatchQueue.main.async { searchFocused = true }
        }
        // ⌘⌫: delete the current selection via the existing confirm dialog.
        .onChange(of: model.deleteRequestToken) {
            if let g = model.selectedGroup { pendingGroupDelete = g }
            else if let s = model.sessions.selectedSession { pendingDelete = s }
        }
    }
}

/// A group's sidebar row: the 2×2 member tile and the name, selected like a tab. The tile
/// carries the unread dot (new messages since you last looked) and the pause dot (the agents
/// used their budget), in the rail as well.
private struct GroupRow: View {
    @EnvironmentObject var model: AppModel
    let group: ChatGroup
    var collapsed: Bool
    var selected: Bool
    var onSelect: () -> Void
    var onRename: () -> Void
    var onRequestDelete: () -> Void
    @State private var showMembers = false

    var body: some View {
        ItemButton(
            icon: {
                GroupTileView(looks: model.memberSessions(group).map(AvatarLook.init(session:)),
                              unread: model.groupHasUnread(group), paused: group.isPaused)
            },
            name: group.name, collapsed: collapsed, selected: selected,
            onSelect: onSelect, onEditIcon: onSelect,
            trailing: { EmptyView() }
        )
        .help(group.name)
        .popover(isPresented: $showMembers, arrowEdge: .trailing) {
            GroupMembersPopover(groupID: group.id)
        }
        .contextMenu {
            Button("Rename…", action: onRename)
            Button("Members…") { showMembers = true }
            Divider()
            Button("Delete Group…", role: .destructive) { onRequestDelete() }
        }
        .accessibilityIdentifier("group-\(group.name)")
    }
}

/// The group tile: a rounded square like `Avatar` holding up to four member avatars (2×2,
/// `GroupTile.cells`), empty cells left blank.
struct GroupTileView: View {
    let looks: [AvatarLook]
    var unread = false
    var paused = false
    var size: CGFloat = SidebarMetrics.icon

    private var cell: CGFloat { (size - 6 - 2) / 2 }

    var body: some View {
        let cells = GroupTile.cells(looks)
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(Theme.chipBackground)
            Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                ForEach(0..<2, id: \.self) { r in
                    GridRow {
                        ForEach(0..<2, id: \.self) { c in
                            if let look = cells[r * 2 + c] {
                                look.avatar(cell)
                            } else {
                                Color.clear.frame(width: cell, height: cell)
                            }
                        }
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .topTrailing) {
            if unread { dot(Theme.attention, label: "New messages").offset(x: 3, y: -3) }
        }
        .overlay(alignment: .bottomTrailing) {
            if paused { dot(Theme.busyAmber, label: "Paused").offset(x: 3, y: 3) }
        }
    }

    private func dot(_ color: Color, label: String) -> some View {
        Circle().fill(color).frame(width: 9, height: 9)
            .overlay(Circle().stroke(Theme.sidebarBackground, lineWidth: 1.5))
            .help(label)
            .accessibilityLabel(label)
    }
}

/// One selectable item button — icon only (collapsed) or icon + name (expanded).
private struct ItemButton<Icon: View, Trailing: View>: View {
    @ViewBuilder var icon: () -> Icon
    let name: String
    let collapsed: Bool
    let selected: Bool
    let onSelect: () -> Void
    let onEditIcon: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    private var avatar: some View { icon() }

    var body: some View {
        HStack(spacing: 10) {
            if collapsed {
                // Rail: the avatar IS the select target; edit via right-click.
                avatar
            } else {
                // Expanded: clicking the avatar opens the color/icon editor; the rest
                // of the row selects.
                Button(action: onEditIcon) { avatar }
                    .buttonStyle(.plain)
                    .help("Edit name, color, and icon")
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
                trailing()
            }
        }
        .frame(maxWidth: collapsed ? .infinity : nil, alignment: collapsed ? .center : .leading)
        .padding(.horizontal, collapsed ? 0 : 16)
        .frame(height: SidebarMetrics.row)
        .background(Rectangle().fill(selected ? Theme.rowSelection : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        // NOTE: do NOT make the row `.focusable()` with `.onKeyPress`. SwiftUI's focus
        // engine then intercepts Return-family keys (incl. Shift+Return) at the window
        // level even while the terminal NSView is first responder, breaking newline-in-
        // prompt in claude's TUI. Keyboard selection is via ⌃⇥ / ⌘1–9 instead. The
        // a11y traits below are VoiceOver-only and don't affect key routing.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(name)
    }
}

/// Shared metrics so item rows and action buttons line up exactly.
enum SidebarMetrics {
    static let icon: CGFloat = 26
    static let row: CGFloat = 36
    static let miniIcon: CGFloat = 13
    static let miniRow: CGFloat = 20
}

struct SessionRow: View {
    @EnvironmentObject var model: AppModel
    let session: AgentSession
    var collapsed: Bool
    var selected: Bool
    var onSelect: () -> Void = {}
    var onRequestDelete: () -> Void = {}
    @State private var editing = false

    private var key: UUID { model.memberKey(for: session) }

    var body: some View {
        ItemButton(
            icon: {
                // While busy a comet orbits the avatar. Unseen work shows as a badge on it in the
                // rail (where the trailing slot is hidden); expanded rows show the dot there.
                Avatar(session: session, size: SidebarMetrics.icon)
                    .overlay { if session.status == .busy { CometRing(size: SidebarMetrics.icon + 7) } }
                    .overlay(alignment: .topTrailing) {
                        if session.hasUnseenWork && collapsed { UnseenWorkDot(badge: true).offset(x: 2, y: -2) }
                    }
            },
            name: session.displayTitle, collapsed: collapsed, selected: selected,
            onSelect: onSelect, onEditIcon: { editing = true },
            trailing: {
                // An ACP tab names its agent here — the provider badge's slot — so a tab in a
                // container never reads as one on this Mac.
                if case let .acp(agentName) = session.backend { AgentBadge(name: agentName) }
                if let sid = session.claudeSessionID,
                   model.watchdog.phase(forSession: sid) != .disarmed {
                    Image(systemName: "binoculars.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.secondaryText)
                        .help("Watchdog armed — right-click to disable")
                }
                if session.hasUnseenWork { UnseenWorkDot(badge: false) }
            }
        )
        .help(session.displayTitle)
        .popover(isPresented: $editing, arrowEdge: .trailing) {
            AvatarEditorPopover(
                initialName: session.customName ?? session.displayTitle,
                initialColorHex: session.avatarColorHex,
                initialSymbol: session.avatarSymbolName,
                onCommitName: { model.sessions.rename(session.id, to: $0) },
                onCommitAppearance: { model.sessions.setAppearance(session.id, colorHex: $0, symbol: $1) },
                initialTeam: session.teamName,
                onCommitTeam: { model.sessions.setTeam(session.id, team: $0) }
            )
        }
        .contextMenu {
            Button("Edit Name, Color & Icon…") { editing = true }
            if let reason = model.forkDisabledReason(session) {
                // A disabled menu item cannot show a tooltip, so the reason rides on its title.
                Button("Fork Session (\(reason))") {}.disabled(true)
            } else {
                Button("Fork Session") { model.fork(session.id) }
            }
            if session.backend.isACP {
                Button("Show ACP Log") { model.showACPLog(session) }
            }
            // Managed (claude) sessions only — reload resumes the transcript, which a plain
            // shell doesn't have.
            if session.claudeSessionID != nil {
                Button("Reload Tab") { model.reload(session.id) }
            }
            // Watchdog opt-out is per tab; arming stays automatic (trigger phrase in a prompt).
            if let sid = session.claudeSessionID {
                Button(model.watchdog.sessionEnabled(sid) ? "Disable Watchdog" : "Enable Watchdog") {
                    model.watchdog.setSessionEnabled(sid, !model.watchdog.sessionEnabled(sid))
                }
            }
            let groupItems = GroupUIGate.tabMenu(groupsEnabled: model.groupsEnabled, member: key,
                                                 groups: model.groupStore.groups)
            if !groupItems.isEmpty {
                Divider()
                ForEach(groupItems.indices, id: \.self) { i in groupMenuItem(groupItems[i]) }
            }
            Divider()
            Button("Delete Session…", role: .destructive) { onRequestDelete() }
        }
        .accessibilityIdentifier("session-\(session.callsign)")
    }

    @ViewBuilder
    private func groupMenuItem(_ item: GroupUIGate.TabMenuItem) -> some View {
        switch item {
        case .newGroupWithTab:
            Button("New group with this tab…") { model.requestNewGroup(preselected: [key]) }
        case .addToGroup(let ids):
            Menu("Add to group") {
                ForEach(ids, id: \.self) { id in
                    if let group = model.groupStore.group(id) {
                        Button(group.name) { _ = model.addGroupMember(key, to: id) }
                    }
                }
            }
        }
    }
}

/// The agent an ACP tab runs on, as a small capsule in the row's trailing slot.
struct AgentBadge: View {
    let name: String

    var body: some View {
        Text(name.count > 16 ? name.prefix(15) + "\u{2026}" : name)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(Theme.secondaryText)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Theme.chipBackground))
            .help("Runs on the ACP agent \u{201C}\(name)\u{201D}")
            .accessibilityIdentifier("agent-badge")
    }
}

/// Half-scale row for a scratch tab: smaller avatar and text, no drag, no
/// reorder, skipped by keyboard navigation. Right-click offers exactly Promote and
/// Delete — promotion re-uses the New… rename step; deletion the normal confirm.
private struct MiniSessionRow: View {
    let session: AgentSession
    var collapsed: Bool
    var selected: Bool
    var onSelect: () -> Void
    var onPromote: () -> Void
    var onRequestDelete: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Avatar(colorHex: session.avatarColorHex, symbol: session.avatarSymbolName,
                   size: SidebarMetrics.miniIcon)
                .overlay { if session.status == .busy { CometRing(size: SidebarMetrics.miniIcon + 5) } }
            if !collapsed {
                Text(session.displayTitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: collapsed ? .infinity : nil, alignment: collapsed ? .center : .leading)
        .padding(.horizontal, collapsed ? 0 : 14)
        .frame(height: SidebarMetrics.miniRow)
        .background(Rectangle().fill(selected ? Theme.rowSelection : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .help(session.displayTitle)
        .contextMenu {
            Button("Promote to Permanent Tab…") { onPromote() }
            Divider()
            Button("Delete", role: .destructive) { onRequestDelete() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(session.displayTitle)
        .accessibilityIdentifier("temp-session-\(session.callsign)")
    }
}

/// A bottom action button — icon only (collapsed) or icon + label (expanded).
private struct ActionButton: View {
    let icon: String
    let label: String
    var shortcut: String = ""
    let collapsed: Bool
    let id: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: SidebarMetrics.icon, height: SidebarMetrics.icon)
                if !collapsed {
                    Text(label).font(.system(size: 13))
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: collapsed ? .infinity : nil, alignment: collapsed ? .center : .leading)
            .foregroundStyle(Theme.secondaryText)
            .padding(.horizontal, collapsed ? 0 : 8)
            .frame(height: SidebarMetrics.row)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(shortcut.isEmpty ? label : "\(label) (\(shortcut))")
        .accessibilityIdentifier(id)
    }
}

/// The Anthropic API server toggle — an ActionButton-shaped row that also renders
/// state: accent tint + live port + a green dot while the server is up. A separate
/// view (not ActionButton flags) because the on-state label/tint/trailing dot are
/// state displays, not a fire-and-forget action.
private struct ServerToggleRow: View {
    @EnvironmentObject var model: AppModel
    let collapsed: Bool

    private var running: Bool { model.apiServerPort != nil }
    private var baseURL: String { "http://127.0.0.1:\(model.apiServerPort ?? 0)" }

    var body: some View {
        Button { model.toggleAPIServer() } label: {
            HStack(spacing: 10) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: SidebarMetrics.icon, height: SidebarMetrics.icon)
                    .foregroundStyle(running ? Theme.accent : Theme.secondaryText)
                if !collapsed {
                    Text(running ? "API Server :\(String(model.apiServerPort ?? 0))" : "API Server")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryText)
                    Spacer(minLength: 0)
                    if running {
                        Circle().fill(Theme.checkGreen).frame(width: 8, height: 8)
                            .accessibilityLabel("API server running")
                    }
                }
            }
            .frame(maxWidth: collapsed ? .infinity : nil, alignment: collapsed ? .center : .leading)
            .padding(.horizontal, collapsed ? 0 : 8)
            .frame(height: SidebarMetrics.row)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(running ? "Serving \(baseURL) — click to stop" : "Start Anthropic API server")
        .accessibilityIdentifier("api-server-toggle")
        .contextMenu {
            if running {
                Button("Copy base URL") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(baseURL, forType: .string)
                }
            }
        }
    }
}

/// The Schedules entry — an ActionButton-shaped row that also renders state: the line from
/// `SchedulerService.sidebarLine` (the one enabled schedule and its countdown, or how many are
/// enabled and the soonest countdown), and a red dot while any schedule's latest fire went
/// wrong (`Overview.needsAttention`). Collapsed, it is the clock and the dot.
private struct SchedulesRow: View {
    @EnvironmentObject var model: AppModel
    let collapsed: Bool
    @State private var overviews: [SchedulerService.Overview] = []
    /// Re-read on a timer, like the Schedules sheet, so the countdown moves and a run's outcome
    /// shows without opening anything.
    private let refresh = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    private var needsAttention: Bool { overviews.contains(where: \.needsAttention) }

    var body: some View {
        Button { model.openSchedules() } label: {
            HStack(spacing: 10) {
                Image(systemName: "clock")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: SidebarMetrics.icon, height: SidebarMetrics.icon)
                    .overlay(alignment: .topTrailing) {
                        if collapsed && needsAttention { dot(badge: true).offset(x: 2, y: -2) }
                    }
                if !collapsed {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Schedules").font(.system(size: 13))
                        if let line = SchedulerService.sidebarLine(overviews, now: Date()) {
                            HStack(spacing: 0) {
                                Text(line.lead).lineLimit(1).truncationMode(.tail)
                                if let countdown = line.countdown { Text(" · " + countdown).fixedSize() }
                            }
                            .font(.system(size: 10))
                        }
                    }
                    Spacer(minLength: 0)
                    if needsAttention { dot(badge: false) }
                }
            }
            .frame(maxWidth: collapsed ? .infinity : nil, alignment: collapsed ? .center : .leading)
            .foregroundStyle(Theme.secondaryText)
            .padding(.horizontal, collapsed ? 0 : 8)
            .frame(height: SidebarMetrics.row)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Schedules (\(Shortcuts.schedules))")
        .accessibilityIdentifier("schedules-open")
        .onAppear(perform: reload)
        .onReceive(refresh) { _ in reload() }
        .onChange(of: model.showSchedules) { reload() }
    }

    private func reload() { overviews = model.scheduler.overview() }

    /// Red as the Schedules sheet shows a failed run; the rail variant is ringed in the sidebar
    /// color so it reads against the icon, like `UnseenWorkDot`'s badge.
    private func dot(badge: Bool) -> some View {
        Circle()
            .fill(ScheduleStyle.color(.failed))
            .frame(width: badge ? 9 : 8, height: badge ? 9 : 8)
            .overlay { if badge { Circle().stroke(Theme.sidebarBackground, lineWidth: 1.5) } }
            .accessibilityLabel("A schedule needs attention")
    }
}

struct Avatar: View {
    let tint: Color
    let symbol: String
    var size: CGFloat = 30
    @Environment(\.self) private var environment

    init(tint: Color, symbol: String, size: CGFloat = 30) {
        self.tint = tint; self.symbol = symbol; self.size = size
    }
    init(colorHex: String?, symbol: String, size: CGFloat = 30) {
        self.init(tint: colorHex.flatMap(Color.init(hexString:)) ?? Theme.accent, symbol: symbol, size: size)
    }
    init(session: AgentSession, size: CGFloat = 30) {
        self.init(colorHex: session.avatarColorHex, symbol: session.avatarSymbolName, size: size)
    }

    /// A faint sheen at the top-left, a touch of depth at the bottom-right, opaque at both
    /// ends. Fading to 55% opacity let the background through: orange went brown on the dark
    /// sidebar, and every tile washed out on the light one.
    private var fill: LinearGradient {
        LinearGradient(
            colors: [tint.mix(with: .white, by: 0.10), tint.mix(with: .black, by: 0.06)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    /// White where it reads on the tile (`GlyphContrast`), else a deep shade of the tile's own
    /// color — white on yellow or a pale custom color was barely visible.
    private var glyph: Color {
        let c = tint.resolve(in: environment)
        let whiteReads = GlyphContrast.whiteReads(linearRed: Double(c.linearRed),
                                                  linearGreen: Double(c.linearGreen),
                                                  linearBlue: Double(c.linearBlue))
        return whiteReads ? .white : tint.mix(with: .black, by: 0.62)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(fill)
            Image(systemName: symbol)
                .font(.system(size: size * 0.46, weight: .bold))
                .foregroundStyle(glyph)
        }
        .frame(width: size, height: size)
    }
}

/// The "unseen completed work" indicator: a session finished a turn while you weren't on
/// its tab. `badge` is the rail variant — ringed in the sidebar color so it reads against
/// the avatar; the expanded variant is a plain dot in the row's trailing slot.
struct UnseenWorkDot: View {
    var badge: Bool = false

    var body: some View {
        Circle()
            .fill(Theme.attention)
            .frame(width: badge ? 9 : 8, height: badge ? 9 : 8)
            .overlay {
                if badge {
                    Circle().stroke(Theme.sidebarBackground, lineWidth: 1.5)
                }
            }
            .help("Finished — you haven't looked at this session yet")
            .accessibilityLabel("Unseen completed work")
    }
}

/// A small themed delete confirmation. Keyboard-first: Return confirms (the Delete button
/// is the default action), Esc cancels — no Full Keyboard Access required. Colors come
/// from the app theme so it matches the rest of the UI.
struct ConfirmDeleteSheet: View {
    let title: String
    let message: String
    var confirmLabel = "Delete"
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmLabel) { onConfirm(); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .accessibilityIdentifier("confirm-delete")
            }
        }
        .padding(20)
        .frame(width: 380)
        .background(Theme.contentBackground)
    }
}
