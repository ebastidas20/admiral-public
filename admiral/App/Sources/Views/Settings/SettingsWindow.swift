import SwiftUI
import AdmiralCore

/// The Settings sheet (feature 1e), laid out like the Schedules sheet: a category list on the
/// left, the chosen section on the right under its title. Closed by the system's Close button
/// (`ButtonRole.close`): every setting applies as it changes, so closing loses nothing.
/// Wired: Appearance (theme), Sessions (launch options), Watchdog (goals + the watchdog's rules),
/// Tickets (patterns + Jira connector), Bridge & API (server/port/scratch tabs), Notifications,
/// Experimental Features (the config's feature flags). Shortcuts remains a placeholder.
///
/// There is no Governance section: hook governance lives in `hookd` (a separate repo),
/// configured by editing its Python rules, not from this window.
struct SettingsWindow: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var section: SettingsSection

    /// Opens on `section`: Appearance from the menu, any section from `-probeSheets`.
    init(section: SettingsSection = .appearance) {
        _section = State(initialValue: section)
    }

    enum SettingsSection: String, CaseIterable, Identifiable {
        case appearance = "Appearance", sessions = "Sessions",
             watchdog = "Watchdog", tickets = "Tickets", bridge = "Bridge & API",
             notifications = "Notifications", experimental = "Experimental Features",
             shortcuts = "Shortcuts"
        var id: String { rawValue }

        /// The list row's symbol, and the line under the section's title.
        var face: (icon: String, summary: String) {
            switch self {
            case .appearance: return ("circle.lefthalf.filled", "How Admiral looks.")
            case .sessions: return ("terminal", "How new tabs launch, and what bash tabs reopen.")
            case .watchdog: return ("eye", "Goal nudges, the watchdog, and the rules it follows.")
            case .tickets: return ("ticket", "Ticket keys found in a session's chat, and their status.")
            case .bridge: return ("network", "The local API server, scratch tabs, and the bridge socket.")
            case .notifications: return ("bell", "Notification Center posts from background sessions.")
            case .experimental: return ("flask", "Features still settling in, each behind its own switch.")
            case .shortcuts: return ("keyboard", "Coming soon.")
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            list.frame(width: 220)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                header
                pane.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 860, height: 600)
        .background(Theme.surface)
        .id(model.config.features.stealthTheme)  // repaints when the flag flips; see RootView
        // A cancellation action, never the default button: Return belongs to the fields that
        // commit on it (port, idle minutes, the Jira secret).
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                SheetCloseButton(identifier: "settings-close") { dismiss() }
            }
        }
    }

    /// The sections the list offers: Bridge & API only while the API server feature is on.
    static func sections(_ features: AdmiralConfig.Features) -> [SettingsSection] {
        SettingsSection.allCases.filter { $0 != .bridge || features.apiServer }
    }

    // MARK: - List

    private var list: some View {
        let sections = Self.sections(model.config.features)
        return VStack(alignment: .leading, spacing: 0) {
            SheetListHeader("Settings")
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(sections) { row($0) }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
        .background(Theme.sidebarBackground)
        .onAppear {
            if !sections.contains(section) { section = sections.first ?? .appearance }
        }
    }

    private func row(_ s: SettingsSection) -> some View {
        Button { section = s } label: {
            HStack(spacing: 8) {
                Image(systemName: s.face.icon)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 16)
                Text(s.rawValue)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(section == s ? Theme.rowSelection : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings-section-\(s.rawValue)")
    }

    // MARK: - Detail

    /// The section's title and what it is for, as the Schedules editor heads a schedule.
    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(section.rawValue)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
            Text(section.face.summary).font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    @ViewBuilder private var pane: some View {
        switch section {
        case .sessions:
            SessionLaunchView(store: model.launchOptionsStore, bashRestoreStore: model.bashRestoreStore)
        case .appearance:
            AppearanceSettingsView()
        case .bridge:
            BridgeAPIView()
        case .notifications:
            NotificationsSettingsView()
        case .watchdog:
            WatchdogSettingsView()
        case .tickets:
            TicketsSettingsView()
        case .experimental:
            ExperimentalSettingsView()
        default:
            VStack(spacing: 10) {
                Image(systemName: section.face.icon)
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Theme.secondaryText)
                Text("Nothing to set here yet")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                Text("Settings for this section are coming soon.")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
