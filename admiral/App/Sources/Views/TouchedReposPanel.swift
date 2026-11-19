import SwiftUI
import AppKit
import AdmiralCore

/// Right-side panel listing the distinct git repos the selected session has written to, each
/// with the same PR chips as the status bar. Default hidden; toggled from the toolbar or ⇧⌘R.
struct TouchedReposPanel: View {
    @EnvironmentObject var model: AppModel
    /// Set by the Goals `…` menu; the confirmation is up while this is non-nil.
    @State private var clearingGoals: GoalsToClear?
    /// A group member's goals section, opened or closed by hand; absent = its default.
    @State private var memberExpanded: [UUID: Bool] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let group = model.selectedGroup {
                header(group.name, symbol: "person.2.fill")
                groupBody(group)
            } else {
                header("Footprint", symbol: nil)
                tabBody
            }
        }
        .frame(width: 280)
        .paneBackground(Theme.contentBackground)
        // The same themed confirm as deleting a session: clearing forgets met goals too.
        .sheet(item: $clearingGoals) { request in
            ConfirmDeleteSheet(
                title: "Clear “\(request.title)”'s goals?",
                message: "Every goal on this session is removed, met ones included, and it stops "
                    + "being reminded of them. This can't be undone.",
                confirmLabel: "Clear Goals",
                onConfirm: { model.goalsStore.set(nil, forSession: request.sid) }
            )
        }
    }

    /// "Footprint" for a tab; the group's name (and a group glyph) for a group, so a group's
    /// footprint never reads as a tab's.
    private func header(_ title: String, symbol: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(Theme.secondaryText)
                }
                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                    .accessibilityIdentifier("footprint-title")
                Spacer()
                Button { model.showTouchedReposPanel = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("Hide (\(Shortcuts.toggleRepos))")
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            Divider().opacity(0.5)
        }
    }

    // MARK: - A tab

    @ViewBuilder
    private var tabBody: some View {
            // An ACP tab: its agent, why it is down, and which features are off and why.
            if let session = model.sessions.selectedSession, case let .acp(agentName) = session.backend {
                AcpFootprintSection(session: session, agentName: agentName)
                Divider().opacity(0.5)
            }
            if let session = model.sessions.selectedSession,
               !session.touchedRepos.isEmpty || !session.tickets.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !session.tickets.isEmpty {
                            TicketsSection(tickets: session.tickets)
                            Divider().opacity(0.3)
                        }
                        if session.touchedRepos.isEmpty {
                            Text("No repositories touched yet")
                                .font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                        } else {
                            ForEach(session.touchedRepos) { RepoRow(repo: $0) }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("No repositories touched yet")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                    .padding(12)
                Spacer()
            }

            checklists
    }

    // MARK: - A group

    /// One deduplicated list of every member's repos and tickets (`GroupFootprint.merge`),
    /// each row with the avatars of the members that touched it; then each member's own
    /// Task List and Goals, unmerged, in a collapsible section.
    @ViewBuilder
    private func groupBody(_ group: ChatGroup) -> some View {
        let members = model.memberSessions(group)
        let footprint = GroupFootprint.merge(members.map {
            GroupFootprint.Member(key: model.memberKey(for: $0), repos: $0.touchedRepos, tickets: $0.tickets)
        })
        let looks = Dictionary(members.map { (model.memberKey(for: $0), AvatarLook(session: $0)) },
                               uniquingKeysWith: { first, _ in first })
        let looksFor: ([UUID]) -> [AvatarLook] = { $0.compactMap { looks[$0] } }

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    if !footprint.tickets.isEmpty {
                        TicketsSection(tickets: footprint.tickets.map(\.ticket),
                                       members: Dictionary(uniqueKeysWithValues: footprint.tickets.map {
                                           ($0.ticket.key, looksFor($0.members))
                                       }))
                        Divider().opacity(0.3)
                    }
                    if footprint.repos.isEmpty {
                        Text("No repositories touched yet")
                            .font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                    } else {
                        ForEach(footprint.repos) { row in
                            RepoRow(repo: row.repo, members: looksFor(row.members))
                        }
                    }
                }
                .padding(12)

                ForEach(members) { member in
                    Divider().opacity(0.5)
                    memberSection(member)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A member's own Task List and Goals, the way a tab's panel draws them, under a header
    /// with its avatar and callsign. Starts expanded only while it has an open goal.
    @ViewBuilder
    private func memberSection(_ member: AgentSession) -> some View {
        let key = model.memberKey(for: member)
        let tasks = model.sessions.conversations[member.id]?.plan?.items ?? []
        let sid = member.claudeSessionID
        let goals = sid.flatMap { model.goalsStore.goals(forSession: $0) }?.checklistItems ?? []
        let open = goals.filter { $0.state != .completed }.count
        let expanded = memberExpanded[key] ?? GroupFootprint.memberExpandedByDefault(openGoals: open)
        let empty = tasks.isEmpty && goals.isEmpty

        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { memberExpanded[key] = !expanded }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.secondaryText)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 10)
                    AvatarLook(session: member).avatar(16)
                    Text(member.callsign)
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(empty ? "no goals" : "\(open) open")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.secondaryText)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("footprint-member-\(member.callsign)")

            if expanded {
                if empty {
                    Text("No goals or tasks")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                        .padding(.horizontal, 12).padding(.bottom, 10)
                } else {
                    SessionChecklist(title: "Task List", items: tasks)
                    if !tasks.isEmpty, !goals.isEmpty {
                        Divider().opacity(0.3).padding(.horizontal, 12)
                    }
                    if let sid { goalsChecklist(goals, title: member.displayTitle, sid: sid) }
                }
            }
        }
    }

    // MARK: - Checklists

    /// The session's Task List and Goals, pinned to the bottom of the panel. Each section
    /// draws nothing when it is empty, and the hairline above only appears when at least one
    /// of them has something to say — so a session with neither looks exactly like before.
    @ViewBuilder
    private var checklists: some View {
        let session = model.sessions.selectedSession
        let tasks = session.flatMap { model.sessions.conversations[$0.id]?.plan?.items } ?? []
        let sid = session?.claudeSessionID
        let goals = sid.flatMap { model.goalsStore.goals(forSession: $0) }?.checklistItems ?? []

        if !tasks.isEmpty || !goals.isEmpty {
            Divider().opacity(0.5)
            SessionChecklist(title: "Task List", items: tasks)
            if !tasks.isEmpty, !goals.isEmpty {
                Divider().opacity(0.3).padding(.horizontal, 12)
            }
            if let session, let sid {
                goalsChecklist(goals, title: session.displayTitle, sid: sid)
            }
        }
    }

    /// The Goals section and what a person can decide from it: a goal's outcome from its
    /// right-click menu — the same merge `update_goals` makes — and clearing them all from `…`.
    /// Both write through `GoalsStore`, whose change notice is what redraws this panel.
    private func goalsChecklist(_ items: [PlanItem], title: String, sid: String) -> some View {
        SessionChecklist(title: "Goals", items: items) { item in
            // A completed row is a met goal; cancelled goals never reach the panel.
            let met = item.state == .completed
            Button(met ? "Reopen" : "Mark Met") { setGoal(item.id, to: met ? .open : .met, sid: sid) }
            Button("Cancel Goal") { setGoal(item.id, to: .cancelled, sid: sid) }
        } accessory: {
            Menu {
                Button("Clear Goals…") { clearingGoals = GoalsToClear(sid: sid, title: title) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Goal actions")
            .accessibilityIdentifier("goals-menu")
        }
    }

    private func setGoal(_ id: String, to status: GoalStatus, sid: String) {
        model.goalsStore.update(forSession: sid) { $0.apply(statuses: [id: status]) }
    }
}

private enum FootprintMetrics {
    /// A row's member avatars: the height of the row's tags, so they never push the row taller.
    static let avatar: CGFloat = 14
}

/// Which session's goals the Clear confirmation is about.
private struct GoalsToClear: Identifiable {
    let sid: String
    let title: String
    var id: String { sid }
}

/// Ticket keys mentioned in the session's chat. Each row opens the ticket in the browser;
/// the status pill only appears while a Tickets connector (Jira) is signed in.
private struct TicketsSection: View {
    let tickets: [TicketRef]
    /// Ticket key → the avatars of the group members that mentioned it; empty for a tab.
    var members: [String: [AvatarLook]] = [:]
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tickets").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondaryText)
            ForEach(tickets) { ticket in
                Button { model.openTicket(ticket.key) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "ticket").font(.system(size: 10)).foregroundStyle(Theme.secondaryText)
                        Text(ticket.key)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.primaryText)
                        if let status = ticket.statusName { pill(status, color(ticket.statusCategory)) }
                        Spacer(minLength: 0)
                        if let looks = members[ticket.key], !looks.isEmpty {
                            AvatarStack(looks: looks, size: FootprintMetrics.avatar)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(ticket.summary.map { "\($0)\nOpen \(ticket.key)" } ?? "Open \(ticket.key)")
                .accessibilityIdentifier("footprint-ticket-\(ticket.key)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func color(_ category: TicketRef.StatusCategory) -> Color {
        switch category {
        case .todo: return Theme.secondaryText
        case .inProgress: return Theme.inProgressBlue
        case .done: return Theme.checkGreen
        case .unknown: return Theme.secondaryText
        }
    }

    private func pill(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 9, weight: .medium)).foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.15)))
    }
}

/// One repo row: folder name + a root/outside tag + full path + a PR chip-group for every PR
/// the repo's branches have (one repo can span several branches → several PRs).
private struct RepoRow: View {
    let repo: TouchedRepo
    /// The group members that touched it; empty for a tab, which draws no avatars.
    var members: [AvatarLook] = []
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                Text((repo.root as NSString).lastPathComponent)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.primaryText)
                if repo.insideSessionRoot { tag("root", Theme.accent) }
                else { tag("outside root", Theme.busyAmber) }
                if !members.isEmpty {
                    Spacer(minLength: 4)
                    AvatarStack(looks: members, size: FootprintMetrics.avatar)
                }
            }
            copyablePath
            ForEach(repo.prs, id: \.number) { pr in
                RepoPRRow(root: repo.root, pr: pr)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The repo path, click-to-copy. macOS has no system "copied" toast, so the row gives
    /// inline confirmation: the label briefly flips to "Copied" with a checkmark, then reverts.
    private var copyablePath: some View {
        Button(action: copyPath) {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.system(size: 9))
                Text(copied ? "Copied" : (repo.root as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 10))
                    .lineLimit(1).truncationMode(.middle)
            }
            .foregroundStyle(copied ? Theme.accent : Theme.secondaryText)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Copy path to clipboard")
    }

    private func copyPath() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(repo.root, forType: .string)
        withAnimation(.easeInOut(duration: 0.15)) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(.easeInOut(duration: 0.25)) { copied = false }
        }
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 9, weight: .medium)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.15)))
    }
}

/// One PR's chips within a repo row. Owns its own merge-confirm state so each PR's popover is
/// independent (a repo can list several PRs).
private struct RepoPRRow: View {
    let root: String
    let pr: PRStatus
    @EnvironmentObject var model: AppModel
    @State private var confirmingMerge = false

    var body: some View {
        PRChipsView(pr: pr, confirmingMerge: $confirmingMerge,
                    onMerge: { model.mergeTouchedRepoPR(root: root, number: pr.number) })
    }
}
