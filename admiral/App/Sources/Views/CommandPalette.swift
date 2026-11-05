import SwiftUI
import AdmiralCore

/// One runnable entry in the palette: an app action shown with its keyboard shortcut.
struct PaletteCommand {
    let title: String
    let shortcut: String
    let icon: String
    /// Shown dimmed and does nothing when picked — the row still lists its shortcut.
    var disabled = false
    let run: () -> Void
}

/// A palette item — either an app command, or "send the typed text to the active
/// terminal" so the search box doubles as a prompt.
enum PaletteItem {
    case command(PaletteCommand)
    case prompt(text: String, session: AgentSession)

    var title: String {
        switch self {
        case let .command(c): return c.title
        case let .prompt(_, s): return "Send to @\(s.displayTitle)"
        }
    }
    var icon: String {
        switch self {
        case let .command(c): return c.icon
        case .prompt: return "paperplane.fill"
        }
    }
    var disabled: Bool {
        if case let .command(c) = self { return c.disabled }
        return false
    }
    var trailing: String {
        switch self {
        case let .command(c): return c.shortcut
        case .prompt: return "↵"
        }
    }
}

/// The ⌘/ command palette: type a prompt for the active terminal, or filter and run an
/// app action. With an empty query the action list doubles as the shortcuts cheat sheet.
struct CommandPalette: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let items = items(for: query)
        VStack(spacing: 0) {
            field
            Divider()
            list(items)
        }
        .frame(width: 560)
        .background(Theme.contentBackground)
        .onExitCommand { dismiss() }                 // Esc closes
        .onAppear { fieldFocused = true; selection = 0 }
    }

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(Theme.accent)
            TextField("Ask the active terminal, or type a command…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($fieldFocused)
                .onSubmit { runSelected() }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onChange(of: query) { selection = 0 }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }

    @ViewBuilder
    private func list(_ items: [PaletteItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                        PaletteRow(item: item, selected: i == selection)
                            .id(i)
                            .contentShape(Rectangle())
                            .onTapGesture { run(item) }
                    }
                    if items.isEmpty {
                        Text("No matching actions").font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryText)
                            .frame(maxWidth: .infinity).padding(.vertical, 18)
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 340)
            .onChange(of: selection) { proxy.scrollTo(selection, anchor: .center) }
        }
    }

    // MARK: - Items

    /// Filtered app commands, plus a "send as prompt" row at the end when text is typed
    /// and a terminal is selected (so a free-form prompt always has somewhere to go).
    private func items(for q: String) -> [PaletteItem] {
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        var result = commands
            .filter { trimmed.isEmpty || $0.title.localizedCaseInsensitiveContains(trimmed) }
            .map { PaletteItem.command($0) }
        if !trimmed.isEmpty, let session = model.sessions.selectedSession {
            result.append(.prompt(text: trimmed, session: session))
        }
        return result
    }

    private var commands: [PaletteCommand] {
        var c: [PaletteCommand] = [
            .init(title: "New Claude Code", shortcut: Shortcuts.newClaudeCode, icon: "plus") { model.requestCommission() },
            .init(title: "New Bash", shortcut: Shortcuts.newBash, icon: "terminal") { model.requestBash() },
        ]
        if model.groupsEnabled {
            c.append(.init(title: "New Group…", shortcut: "", icon: "bubble.left.and.bubble.right") {
                model.requestNewGroup()
            })
            if model.selectedGroup != nil {
                c.append(.init(title: "Delete Group…", shortcut: Shortcuts.deleteSelected, icon: "trash") {
                    model.requestDeleteSelected()
                })
            }
        }
        if model.config.features.apiServer {
            c.append(.init(title: model.apiServerPort == nil ? "Start API Server" : "Stop API Server",
                           shortcut: "", icon: "antenna.radiowaves.left.and.right") { model.toggleAPIServer() })
        }
        c += [
            .init(title: "Search", shortcut: Shortcuts.search, icon: "magnifyingglass") { model.requestSearchFocus() },
            .init(title: model.sidebarCollapsed ? "Expand Sidebar" : "Collapse Sidebar",
                  shortcut: Shortcuts.toggleSidebar, icon: "sidebar.left") { model.sidebarCollapsed.toggle() },
        ]
        if model.config.features.chatView {
            c.append(.init(title: model.selectedViewMode == .chat ? "Show Terminal" : "Show Chat",
                           shortcut: Shortcuts.toggleChat, icon: "bubble.left.and.text.bubble.right",
                           disabled: !model.selectedCanToggleView) { model.toggleViewMode() })
        }
        c += [
            .init(title: model.showTouchedReposPanel ? "Hide Footprint" : "Show Footprint",
                  shortcut: Shortcuts.toggleRepos, icon: "sidebar.right") { model.showTouchedReposPanel.toggle() },
            .init(title: "Cycle Appearance", shortcut: Shortcuts.cycleAppearance,
                  icon: "circle.lefthalf.filled") { model.cycleTheme() },
            .init(title: "Settings", shortcut: Shortcuts.settings, icon: "gearshape") { model.openSettings() },
            .init(title: "Schedules", shortcut: Shortcuts.schedules, icon: "clock") { model.openSchedules() },
            .init(title: "Next Session", shortcut: Shortcuts.nextItem, icon: "chevron.down") { model.selectNext() },
            .init(title: "Previous Session", shortcut: Shortcuts.prevItem, icon: "chevron.up") { model.selectPrev() },
        ]
        if model.sessions.selectedScratchTab != nil {
            c.append(.init(title: "Promote to Permanent Tab", shortcut: Shortcuts.promoteTab,
                           icon: "pin") { model.promoteSelected() })
        }
        if model.sessions.selectedSession != nil {
            c.append(.init(title: "Fork Session", shortcut: Shortcuts.forkSession, icon: "arrow.triangle.branch",
                           disabled: model.sessions.selectedSession.flatMap(model.forkDisabledReason) != nil) {
                model.forkSelected()
            })
            c.append(.init(title: "Move Session Up", shortcut: Shortcuts.moveItemUp,
                           icon: "arrow.up") { model.moveSelectedUp() })
            c.append(.init(title: "Move Session Down", shortcut: Shortcuts.moveItemDown,
                           icon: "arrow.down") { model.moveSelectedDown() })
        }
        if model.prStatus != nil {
            c.append(.init(title: "Open Pull Request", shortcut: Shortcuts.openPR,
                           icon: "link") { model.openSelectedPR() })
        }
        if model.prStatus?.canMerge == true {
            c.append(.init(title: "Merge Pull Request", shortcut: Shortcuts.mergePR,
                           icon: "arrow.triangle.merge") { model.requestMergeSelectedPR() })
        }
        if model.sessions.selectedSession != nil {
            c.append(.init(title: "Delete Selected", shortcut: Shortcuts.deleteSelected,
                           icon: "trash") { model.requestDeleteSelected() })
        }
        return c
    }

    // MARK: - Navigation

    private func move(_ delta: Int) {
        let count = items(for: query).count
        guard count > 0 else { return }
        selection = max(0, min(selection + delta, count - 1))
    }

    private func runSelected() {
        let items = items(for: query)
        guard items.indices.contains(selection) else { return }
        run(items[selection])
    }

    /// Close first (so an action that opens its own sheet/picker doesn't fight this one),
    /// then run on the next runloop tick.
    private func run(_ item: PaletteItem) {
        dismiss()
        DispatchQueue.main.async {
            switch item {
            case let .command(c):
                if !c.disabled { c.run() }
            case let .prompt(text, session):
                model.selectTerminal(session.id)
                model.sessions.send(session.id, text: text)
            }
        }
    }
}

private struct PaletteRow: View {
    let item: PaletteItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.icon)
                .font(.system(size: 13))
                .frame(width: 20)
                .foregroundStyle(selected ? Theme.accent : Theme.secondaryText)
            Text(item.title).font(.system(size: 13)).foregroundStyle(Theme.primaryText).lineLimit(1)
            Spacer(minLength: 8)
            Text(item.trailing)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Rectangle().fill(Theme.chipBackground))
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .opacity(item.disabled ? 0.45 : 1)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(selected ? Theme.rowSelection : Color.clear))
    }
}
