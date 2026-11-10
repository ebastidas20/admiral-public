import SwiftUI
import AdmiralCore

/// Settings → Sessions. Edits the `LaunchOptions` every NEW managed claude session
/// launches with, plus the bash TUI reopen allowlist. Persisted through profile-aware
/// stores `AppModel` re-reads, so a change applies on the next commission / quit.
struct SessionLaunchView: View {
    private let store: LaunchOptionsStore
    private let bashRestoreStore: BashRestoreSettingsStore
    @State private var options: LaunchOptions
    @State private var bashRestore: BashRestoreSettings
    /// Re-read when the pane appears: CC Switch is a separate app, edited while Admiral runs.
    @State private var providers: [CCSwitchProvider] = []

    init(store: LaunchOptionsStore, bashRestoreStore: BashRestoreSettingsStore) {
        self.store = store
        self.bashRestoreStore = bashRestoreStore
        _options = State(initialValue: store.load())
        _bashRestore = State(initialValue: bashRestoreStore.load())
    }

    private var selectedProvider: CCSwitchProvider? {
        providers.first { $0.id == options.providerID }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SettingsCard("Managed launch flags",
                        "On, Admiral launches sessions with `command claude` plus the flags "
                            + "below — personal shell aliases and functions are skipped, so "
                            + "sessions behave the same on any machine. Off, Admiral runs plain "
                            + "`claude`: your shell configuration decides, and without a "
                            + "personal wrapper claude uses its standard permission prompts.") {
                    Toggle("Admiral manages claude's launch flags", isOn: bind(\.managed))
                        .toggleStyle(.switch)
                        .accessibilityIdentifier("launch-managed-toggle")
                }

                SettingsCard("Messages from Admiral",
                        "On, new tabs accept messages on claude's own messaging socket "
                            + "(`crossSessionInbound: accept`), and PR WATCH and watchdog "
                            + "checks arrive that way — queued while claude works, and never "
                            + "typed on top of what you are writing. Off, they are typed into "
                            + "the tab. Applies to tabs launched or relaunched after the "
                            + "change. Also lets your other claude sessions message these "
                            + "tabs without review.") {
                    Toggle("Deliver Admiral's messages over the socket",
                           isOn: Binding(get: { options.acceptsPeerMessages },
                                         set: { options.acceptPeerMessages = $0; store.save(options) }))
                        .toggleStyle(.switch)
                        .accessibilityIdentifier("launch-accept-peer-messages")
                }

                Group {
                    SettingsCard("Permission mode",
                            "How claude asks before acting. `bypassPermissions` never prompts "
                                + "(full autonomy — Admiral's default); `acceptEdits` "
                                + "auto-approves file edits only; `default` uses claude's "
                                + "standard prompts; `plan` starts in plan mode.") {
                        Picker("", selection: bind(\.permissionMode)) {
                            ForEach(PermissionMode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden()
                        .accessibilityIdentifier("launch-permission-mode")
                    }

                    SettingsCard("System prompt",
                            "If the session's working directory contains "
                                + "`APPEND_SYSTEM_PROMPT.md`, append its content to claude's "
                                + "system prompt (read at launch time, in the session's cwd).") {
                        Toggle("Append APPEND_SYSTEM_PROMPT.md when present", isOn: bind(\.appendSystemPrompt))
                            .toggleStyle(.switch)
                            .accessibilityIdentifier("launch-append-toggle")
                    }

                    SettingsCard("Extra flags",
                            "Appended verbatim to the `claude` invocation of every new session.") {
                        TextField("--model opus", text: bind(\.extraFlags))
                            .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                            .frame(maxWidth: 420)
                            .accessibilityIdentifier("launch-extra-flags")
                    }
                }
                .disabled(!options.managed)
                .opacity(options.managed ? 1 : 0.4)

                SettingsCard("Custom model",
                        "Which CC Switch config a session uses when you tick “Use custom "
                            + "model” on the New Session form. Choosing one here launches "
                            + "nothing and changes no open tab — it only sets what that "
                            + "checkbox means. CC Switch owns the values; Admiral reads them.") {
                    if providers.isEmpty {
                        Text("No CC Switch configs found at the location below. Add one in "
                             + "CC Switch, or choose its folder or another database.")
                            .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                            .accessibilityIdentifier("launch-provider-empty")
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Picker("", selection: bind(\.providerID)) {
                                Text("None").tag(String?.none)
                                ForEach(providers) { Text($0.name).tag(String?.some($0.id)) }
                            }
                            .labelsHidden().frame(maxWidth: 420, alignment: .leading)
                            .accessibilityIdentifier("launch-provider-picker")

                            if let url = selectedProvider?.baseURL {
                                Text("→ \(url)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Theme.secondaryText)
                                    .textSelection(.enabled)
                                    .accessibilityIdentifier("launch-provider-url")
                            }
                        }
                    }

                    HStack(spacing: 8) {
                        Text(ccSwitchLocationLabel)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("launch-ccswitch-db")
                        Button("Choose…", action: chooseCCSwitchLocation)
                            .accessibilityIdentifier("launch-ccswitch-choose")
                        if options.ccSwitchBookmark != nil {
                            Button("Use default") { setCCSwitchBookmark(nil) }
                                .accessibilityIdentifier("launch-ccswitch-default")
                        }
                    }
                    .frame(maxWidth: 420, alignment: .leading)
                }

                SettingsCard("Bash tab reopen",
                        "When Admiral quits, bash tabs remember an allowlisted TUI that was "
                            + "running (by executable name only — never full command lines). "
                            + "On relaunch that tool is started again in a fresh shell. "
                            + "Anything not on the list is ignored, so a random `kubectl` or "
                            + "`rm` never auto-reruns.") {
                    Toggle("Reopen allowlisted TUIs in bash tabs", isOn: bashEnabledBinding)
                        .toggleStyle(.switch)
                        .accessibilityIdentifier("bash-restore-enabled")

                    Text("One tool name per line (e.g. k9s, htop). No paths or arguments.")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)

                    FieldEditor(text: allowlistBinding, placeholder: "k9s\nhtop", monospaced: true,
                                height: 120, identifier: "bash-restore-allowlist")
                        .disabled(!bashRestore.enabled)
                        .opacity(bashRestore.enabled ? 1 : 0.45)

                    Button("Reset to defaults") {
                        bashRestore = .default
                        bashRestoreStore.save(bashRestore)
                    }
                    .disabled(bashRestore == .default)
                    .accessibilityIdentifier("bash-restore-reset")
                }

                Text("Claude launch flags apply to sessions started after the change. "
                     + "Bash reopen uses the allowlist saved at quit time.")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
            }
            .padding(20)
        }
        .onAppear {
            providers = CCSwitchCatalog.load(bookmark: options.ccSwitchBookmark)
            bashRestore = bashRestoreStore.load()
        }
    }

    private func bind<T>(_ keyPath: WritableKeyPath<LaunchOptions, T>) -> Binding<T> {
        Binding(
            get: { options[keyPath: keyPath] },
            set: { options[keyPath: keyPath] = $0; store.save(options) }
        )
    }

    /// The picked CC Switch location, else the standard one, as the card shows it.
    private var ccSwitchLocationLabel: String {
        let path = options.ccSwitchBookmark.flatMap(CCSwitchCatalog.location(from:))?.path
            ?? CCSwitchCatalog.defaultDatabasePath
        return (path as NSString).abbreviatingWithTildeInPath
    }

    /// Picking the folder (or a database file) — never typing a path — is what grants a
    /// sandboxed Admiral read access to it; the security-scoped bookmark keeps that grant.
    private func chooseCCSwitchLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: CCSwitchCatalog.defaultDatabasePath).deletingLastPathComponent()
        panel.message = "Choose CC Switch's folder (~/.cc-switch) or a cc-switch.db file."
        guard panel.runModal() == .OK, let url = panel.url,
              let bookmark = try? CCSwitchCatalog.bookmark(for: url) else { return }
        setCCSwitchBookmark(bookmark)
    }

    private func setCCSwitchBookmark(_ bookmark: Data?) {
        options.ccSwitchBookmark = bookmark
        store.save(options)
        providers = CCSwitchCatalog.load(bookmark: bookmark)
    }

    private var bashEnabledBinding: Binding<Bool> {
        Binding(
            get: { bashRestore.enabled },
            set: {
                bashRestore.enabled = $0
                bashRestoreStore.save(bashRestore)
            }
        )
    }

    private var allowlistBinding: Binding<String> {
        Binding(
            get: { bashRestore.allowlist.joined(separator: "\n") },
            set: {
                let names = $0.split(whereSeparator: \.isNewline).map(String.init)
                bashRestore.allowlist = BashRestoreSettings.normalize(names)
                bashRestoreStore.save(bashRestore)
            }
        )
    }
}
