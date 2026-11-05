import SwiftUI
import AppKit
import AppIntents

/// Kills every session's process group when the app quits, so no claude / node / MCP
/// child is left orphaned. Sessions themselves are untouched, so they restore on relaunch.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.model?.prepareToTerminate()
    }

    /// `admiral://` URLs (the Jira OAuth redirect). Handled here rather than `onOpenURL` so
    /// SwiftUI never opens a second window for an incoming URL.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { AppState.shared.model?.handleOpenURL(url) }
    }
}

@main
struct AdmiralApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    init() {
        // Register the App Intents dependency on cold start (before any intent runs).
        AppDependencyManager.shared.add(dependency: AppState.shared)
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 940, minHeight: 620)
                .onAppear { model.start() }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands { AdmiralCommands(model: model) }
    }
}

/// App-wide keyboard shortcuts, surfaced as menu items (also aids discoverability +
/// accessibility). Actions route to the shared AppModel.
struct AdmiralCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        // New Claude Code / New Bash under File (replacing the default "New").
        CommandGroup(replacing: .newItem) {
            Button("New Claude Code") { model.requestCommission() }
                .keyboardShortcut("t", modifiers: .command)
            Button("New Bash") { model.requestBash() }
                .keyboardShortcut("t", modifiers: [.command, .control])
            if model.groupsEnabled {
                Button("New Group…") { model.requestNewGroup() }
            }
            Button("Fork Session") { model.forkSelected() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(model.sessions.selectedSession.map { model.forkDisabledReason($0) != nil } ?? true)
        }
        CommandMenu("Session") {
            Button("Search") { model.requestSearchFocus() }
                .keyboardShortcut("f", modifiers: .command)
            Button(model.sidebarCollapsed ? "Expand Sidebar" : "Collapse Sidebar") {
                model.sidebarCollapsed.toggle()
            }
            .keyboardShortcut("b", modifiers: .command)
            Button("Cycle Appearance") { model.cycleTheme() }
                .keyboardShortcut("a", modifiers: [.control, .command])
            if model.config.features.chatView {
                Button(model.selectedViewMode == .chat ? "Show Terminal" : "Show Chat") {
                    model.toggleViewMode()
                }
                .keyboardShortcut("j", modifiers: .command)
                // An ACP tab is Chat only: nothing to switch to.
                .disabled(!model.selectedCanToggleView)
            }
            Divider()
            Button("Promote to Permanent Tab…") { model.promoteSelected() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(model.sessions.selectedScratchTab == nil)
            Divider()
            Button("Next Session") { model.selectNext() }
                .keyboardShortcut(.downArrow, modifiers: .command)
            Button("Previous Session") { model.selectPrev() }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("Move Session Up") { model.moveSelectedUp() }
                .keyboardShortcut(.upArrow, modifiers: [.command, .shift])
            Button("Move Session Down") { model.moveSelectedDown() }
                .keyboardShortcut(.downArrow, modifiers: [.command, .shift])
            ForEach(1...9, id: \.self) { n in
                Button("Select Item \(n)") { model.selectByIndex(n - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
            }
            Divider()
            Button("Open Pull Request") { model.openSelectedPR() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(model.prStatus == nil)
            Button("Merge Pull Request…") { model.requestMergeSelectedPR() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(model.prStatus?.canMerge != true)
            Button(model.showTouchedReposPanel ? "Hide Footprint" : "Show Footprint") {
                model.showTouchedReposPanel.toggle()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Button("Delete Selected…") { model.requestDeleteSelected() }
                .keyboardShortcut(.delete, modifiers: .command)
        }
        CommandGroup(before: .windowArrangement) {
            Button("Schedules…") { model.openSchedules() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Divider()
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { model.openSettings() }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(replacing: .help) {
            Button("Command Palette") { model.showCommandPalette = true }
                .keyboardShortcut("/", modifiers: .command)
        }
    }
}
