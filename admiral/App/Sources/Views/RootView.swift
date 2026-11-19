import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AdmiralCore

enum ViewMode: String, CaseIterable { case transcript, terminal }

struct RootView: View {
    @EnvironmentObject var model: AppModel

    private var activeTitle: String {
        model.selectedGroup?.name ?? model.sessions.selectedSession?.displayTitle ?? "Admiral"
    }

    private var themeIcon: String {
        switch model.themeMode {
        case .auto: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    var body: some View {
        NavigationStack {
            // Header is the real window titlebar (full width, on top); the left bar +
            // detail sit below it (HHHH / LRRR).
            HStack(spacing: 0) {
                SidebarView()
                    .frame(width: model.sidebarCollapsed ? 56 : 232)
                FadingTopDivider()
                DetailView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.showTouchedReposPanel {
                    FadingTopDivider()
                    TouchedReposPanel()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Panes draw below the header only — a scrolled chat would otherwise show through it.
            .clipped()
            // The header's color: one fill reaching up under the (hidden) toolbar background.
            // It must not take clicks — SwiftUI subtracts anything hit-testable under the
            // titlebar from the window's drag region, and with that region empty, dragging the
            // header never moves the window. A `.toolbarBackground` color counts as hit-testable
            // too, which is why the toolbar's own background stays hidden (and why the panes'
            // fills stop at the header — see `paneBackground`).
            .background { Theme.surface.ignoresSafeArea().allowsHitTesting(false) }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button { model.sidebarCollapsed.toggle() } label: {
                        Image(systemName: "sidebar.left")
                    }
                    .help("\(model.sidebarCollapsed ? "Expand" : "Collapse") Sidebar (\(Shortcuts.toggleSidebar))")
                    .accessibilityIdentifier("toggle-sidebar")
                }
                ToolbarItem(placement: .primaryAction) {
                    if model.config.features.chatView, model.selectedGroup == nil,
                       // Not on an ACP tab: Chat is all it has.
                       let session = model.sessions.selectedSession, model.selectedCanToggleView {
                        Picker("View", selection: Binding(
                            get: { model.viewMode(for: session) },
                            set: { model.setViewMode($0, for: session) }
                        )) {
                            Text("Chat").tag(ChatLedger.Mode.chat)
                            Text("Terminal").tag(ChatLedger.Mode.terminal)
                        }
                        .pickerStyle(.segmented)
                        .help("Chat or Terminal (\(Shortcuts.toggleChat))")
                        .accessibilityIdentifier("view-mode")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    CoffeeToolbarButton()
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { model.cycleTheme() } label: {
                        Image(systemName: themeIcon)
                    }
                    .help("Appearance: \(model.themeMode.rawValue) (\(Shortcuts.cycleAppearance))")
                    .accessibilityIdentifier("toggle-theme")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { model.showTouchedReposPanel.toggle() } label: {
                        Image(systemName: "sidebar.right")
                    }
                    .help("\(model.showTouchedReposPanel ? "Hide" : "Show") Footprint (\(Shortcuts.toggleRepos))")
                    .accessibilityIdentifier("toggle-repos")
                }
            }
            .navigationTitle(activeTitle)
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        }
        // The Stealth flag changes dark colors without changing the color scheme, so SwiftUI
        // won't re-resolve them on its own. Inside the sheets so flipping it keeps Settings open.
        .id(model.config.features.stealthTheme)
        .preferredColorScheme(model.preferredColorScheme)
        .sheet(isPresented: $model.showCommandPalette) { CommandPalette() }
        .sheet(isPresented: $model.showNewTerminal) { NewTerminalForm() }
        .sheet(isPresented: $model.showSettings) { SettingsWindow() }
        .sheet(isPresented: $model.showSchedules) { SchedulesWindow() }
        .sheet(item: $model.newGroupSheet) { request in NewGroupSheet(request: request) }
        .sheet(item: $model.acpLogSession) { session in
            if let url = model.acpLogURL(for: session) { AcpLogView(title: session.displayTitle, url: url) }
        }
    }
}

/// Keep-awake toggle (caffeinate -u). Inactive: a plain cup, same as the neighbouring toolbar
/// buttons. Active: the cup fills and its lines become a slowly-flowing rainbow with a soft
/// glow — an unmistakable "I'm holding the Mac awake" cue.
private struct CoffeeToolbarButton: View {
    @EnvironmentObject var model: AppModel
    private let rainbow = AngularGradient(
        colors: [.red, .orange, .yellow, .green, .blue, .purple, .red], center: .center)

    var body: some View {
        Button { model.toggleKeepAwake() } label: { icon }
            .help(model.keepAwake ? "Keep awake: on — the display won't sleep and the Mac stays user-active. Click to turn off."
                                  : "Keep awake — prevent the Mac from sleeping (caffeinate -u)")
            .accessibilityIdentifier("toggle-keep-awake")
    }

    @ViewBuilder private var icon: some View {
        if model.keepAwake {
            // Hue from the clock: a repeating implicit animation also captures the toolbar's
            // launch layout, and the icon then loops in from the corner of its platter.
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                Image(systemName: "cup.and.saucer.fill")
                    .foregroundStyle(rainbow)
                    .hueRotation(.degrees(
                        context.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: 4) / 4 * 360))
                    .shadow(color: .accentColor.opacity(0.55), radius: 4)
            }
        } else {
            Image(systemName: "cup.and.saucer")
        }
    }
}

/// The sidebar/detail separator as a vertical hairline whose top fades to transparent,
/// so the line softly emerges below the titlebar instead of starting with a hard edge.
struct FadingTopDivider: View {
    var fadeHeight: CGFloat = 20

    var body: some View {
        GeometryReader { geo in
            let loc = geo.size.height > 0 ? min(fadeHeight / geo.size.height, 1) : 0
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: loc),
                            .init(color: .black, location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
        }
        .frame(width: 1)
    }
}

struct EmptyDetail: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "sailboat.fill")
                .font(.system(size: 42))
                .foregroundStyle(Theme.accent)
            Text("No session selected")
                .font(.system(size: 16, weight: .semibold))
            Text("Commission a session to begin.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
            Button {
                model.requestCommission()
            } label: {
                Label("Commission session", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("commission-button")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .paneBackground(Theme.contentBackground)
    }
}

extension View {
    /// A pane's fill, kept below the header. A plain `.background(color)` extends up into the
    /// titlebar and is hit-testable there, which empties the window's drag region (see
    /// RootView) — the header then looks fine but no longer drags the window.
    func paneBackground(_ color: Color) -> some View {
        background(color, ignoresSafeAreaEdges: [])
    }
}
