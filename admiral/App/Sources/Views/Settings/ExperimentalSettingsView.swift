import SwiftUI
import AdmiralCore

/// Settings → Experimental Features. One switch per flag in `config.features`, saved to
/// `<support dir>/config.json` (the file they are read from) as soon as one is flipped.
struct ExperimentalSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SettingsCard("Chat view",
                             "Show claude tabs as a chat instead of the raw terminal, with "
                                + "⌘J to swap between them. Off, every tab stays a terminal.") {
                    Toggle("Enable the chat view", isOn: flag(\.chatView))
                        .toggleStyle(.switch)
                        .accessibilityIdentifier("settings-experimental-chatView")
                }
                SettingsCard("Bridge & API server",
                             "The Anthropic-compatible API and operator MCP on localhost, "
                                + "and the Bridge & API settings section. Off, the server "
                                + "is stopped and never starts.") {
                    Toggle("Enable the API server", isOn: flag(\.apiServer))
                        .toggleStyle(.switch)
                        .accessibilityIdentifier("settings-experimental-apiServer")
                }
                SettingsCard("Group chats",
                             "Group tabs into a shared conversation: a group is a sidebar item "
                                + "like any tab, you and the members post to one log, and "
                                + "@name or @all wakes them. Off, no group UI and no group_* "
                                + "bridge tools exist.") {
                    Toggle("Enable group chats", isOn: flag(\.groups))
                        .toggleStyle(.switch)
                        .accessibilityIdentifier("settings-experimental-groups")
                }
                SettingsCard("Stealth theme",
                             "Replace the Dark theme's black with the dark blue of Stealth "
                                + "Browser's top bar. Light is unchanged.") {
                    Toggle("Enable the Stealth theme", isOn: flag(\.stealthTheme))
                        .toggleStyle(.switch)
                        .accessibilityIdentifier("settings-experimental-stealthTheme")
                }
                Text("Saved to \((AdmiralConfigStore.defaultURL.path as NSString).abbreviatingWithTildeInPath).")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
            }
            .padding(20)
        }
    }

    private func flag(_ key: WritableKeyPath<AdmiralConfig.Features, Bool>) -> Binding<Bool> {
        Binding(get: { model.config.features[keyPath: key] },
                set: { value in
                    var features = model.config.features
                    features[keyPath: key] = value
                    model.updateFeatures(features)
                })
    }
}
