import SwiftUI
import AppKit
import AdmiralCore

/// Settings → Agents: the ACP agents Admiral can open tabs on. A list with add / edit /
/// duplicate / delete, and the selected agent's form below it. Saved to `AcpAgentStore`
/// (profile-aware); the session bridge listener follows the list on its own (defaults change).
struct AgentsSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var agents: [AcpAgentConfig] = []
    /// The agent being edited (a copy until Save), or nil when the form is closed.
    @State private var draft: AcpAgentDraft?
    /// The draft is an agent not yet in the list (Add, Duplicate).
    @State private var draftIsNew = false
    @State private var testing = false
    @State private var confirmingDelete: AcpAgentConfig?
    /// The agent whose delete was refused (tabs open on it), and why — shown under its row.
    @State private var deleteRefused: (id: UUID, reason: String)?
    /// The list row being typed in: its id and which of its fields (0 = argument or key, 1 = value).
    @FocusState private var focusedRow: RowFocus?

    struct RowFocus: Hashable {
        let row: UUID
        let field: Int
    }

    /// Whether the API server feature is on; nil = the config's. Set only by the probe, which
    /// must draw the warning without turning the real server on.
    private let apiServerOn: Bool?

    /// Opens with `editing` in the form (the probe draws a filled form).
    init(editing: AcpAgentConfig? = nil, apiServerOn: Bool? = nil) {
        self.init(draft: editing.map(AcpAgentDraft.init), isNew: false, apiServerOn: apiServerOn)
    }

    /// Opens with `draft` in the form as typed — rows the config cannot hold, like a duplicate key.
    init(draft: AcpAgentDraft?, isNew: Bool, apiServerOn: Bool? = nil) {
        _draft = State(initialValue: draft)
        _draftIsNew = State(initialValue: isNew)
        self.apiServerOn = apiServerOn
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SettingsCard("Agents",
                        "Agents Admiral talks to over ACP (the Agent Client Protocol) instead of "
                            + "running claude in a terminal — for instance claude-agent-acp inside a "
                            + "container, through `docker exec -i`. Their tabs are Chat only. Pin the "
                            + "agent's version (`npx -y @agentclientprotocol/claude-agent-acp@<version>`) "
                            + "rather than an unpinned `npx -y`, so a relaunch never brings a different "
                            + "agent.") {
                    list
                }
                if let draft {
                    form(draft)
                }
            }
            .padding(20)
        }
        .onAppear { agents = model.acpAgentStore.load() }
        .sheet(item: $confirmingDelete) { agent in
            ConfirmDeleteSheet(
                title: "Delete \u{201C}\(agent.name)\u{201D}?",
                message: "Admiral will no longer be able to open tabs on it.",
                confirmLabel: "Delete Agent",
                onConfirm: { delete(agent) })
        }
    }

    // MARK: - List

    @ViewBuilder private var list: some View {
        VStack(alignment: .leading, spacing: 6) {
            if agents.isEmpty {
                Text("No agents yet.")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                    .accessibilityIdentifier("agents-empty")
            }
            ForEach(agents) { agent in
                row(agent)
                if let refused = deleteRefused, refused.id == agent.id {
                    note("exclamationmark.triangle.fill", refused.reason, leading: 10)
                        .accessibilityIdentifier("agent-delete-refused")
                }
            }
            if !agents.isEmpty && apiServerWarningShown { apiServerWarning(leading: 0) }
            HStack {
                Button("Add Agent") { edit(AcpAgentDraft.new(), isNew: true) }
                    .accessibilityIdentifier("agents-add")
                Spacer()
            }
            .padding(.top, 4)
        }
    }

    private func row(_ agent: AcpAgentConfig) -> some View {
        let selected = draft?.id == agent.id
        return HStack(spacing: 10) {
            Image(systemName: "shippingbox").font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.primaryText)
                Text(([agent.launch.command] + agent.launch.args).joined(separator: " "))
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.secondaryText)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button("Edit") { edit(AcpAgentDraft(agent), isNew: false) }
            Button("Duplicate") { duplicate(agent) }
            Button { requestDelete(agent) } label: { Image(systemName: "trash") }
                .help("Delete \(agent.name)")
        }
        .controlSize(.small)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(selected ? Theme.rowSelection : Theme.chipBackground))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agents-row-\(agent.name)")
    }

    // MARK: - Form

    /// The form that works: `npx` fetches the adapter in the container (a bare
    /// `claude-agent-acp` is usually not installed there). Generic names, nobody's setup.
    static let argumentsHint = "One argument per row, e.g. `exec`, `-i`, `my-container`, `npx`, `-y`, "
        + "`@agentclientprotocol/claude-agent-acp@<version>`."

    private func form(_ current: AcpAgentDraft) -> some View {
        let config = current.config
        let errors = current.validationErrors
            + config.validationErrors(among: agents, openTabAgents: openTabAgents)
        return SettingsCard(draftIsNew ? "New agent" : "Edit \u{201C}\(config.name)\u{201D}",
                            "Launched directly — no shell — with one literal argument per row.") {
            VStack(alignment: .leading, spacing: 12) {
                field("Name", \.name, placeholder: "Claude Code (container)", id: "agent-name")
                field("Command", \.command, placeholder: "docker", id: "agent-command", mono: true)
                argList("Arguments", \.args, current.args, placeholders: ["exec"], id: "agent-args")
                caption(Self.argumentsHint)
                if config.passesIgnoredSkipPermissionsFlag {
                    note("exclamationmark.triangle.fill",
                         "claude-agent-acp ignores --dangerously-skip-permissions. "
                             + "Admiral sets the mode below instead.")
                        .accessibilityIdentifier("agent-ignored-flag")
                }
                pairList("Environment", \.env, current.env, placeholder: ("NAME", "value"),
                         add: "Add variable", id: "agent-env")
                caption("Applies to the command on this Mac, not inside a container. "
                        + "Use `docker exec -e` for the agent's environment.")
                field("Folder", \.cwd, placeholder: "/path/in/container", id: "agent-cwd", mono: true)
                caption("Absolute, as the agent sees it (inside the container).")
                field("Mode", \.defaultMode, placeholder: "none", id: "agent-mode", mono: true)
                pairList("Config options", \.configOptions, current.configOptions, placeholder: ("model", "opus"),
                         add: "Add option", id: "agent-options")
                field("Bridge URL", \.mcpCallbackURL, placeholder: "http://host.docker.internal:4142",
                      id: "agent-callback", mono: true)
                execField(current)
                if !errors.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(errors, id: \.self) { error in
                            Label(error, systemImage: "xmark.circle.fill")
                                .font(.system(size: 11)).foregroundStyle(.red)
                        }
                    }
                    .accessibilityIdentifier("agent-errors")
                }
                if apiServerWarningShown { apiServerWarning(leading: 106) }
                testResult(config)
                HStack(spacing: 8) {
                    Button(testing ? "Testing\u{2026}" : "Test Connection") { test(config) }
                        .disabled(testing || !config.validationErrors.isEmpty)
                        .accessibilityIdentifier("agent-test")
                    if testing { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Cancel") { draft = nil }
                    Button("Save") { save(config) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!errors.isEmpty)
                        .accessibilityIdentifier("agent-save")
                }
            }
        }
    }

    /// The exec prefix: empty = the one derived from the launch command, shown under it, and
    /// one click away from being edited.
    @ViewBuilder private func execField(_ current: AcpAgentDraft) -> some View {
        let config = current.config
        let derived = AcpAgentConfig.derivedExec(from: config.launch)
        argList("Exec", \.exec, current.exec,
                placeholders: derived.map { [$0.command] } ?? ["docker"], id: "agent-exec")
        HStack(spacing: 6) {
            if config.exec == nil, let derived {
                caption("Empty: derived from the launch command — `\(Self.oneLine(derived))`.")
                Button("Edit") { draft?.exec = AcpArgList([derived.command] + derived.args) }
                    .controlSize(.small).buttonStyle(.link)
            } else if config.exec == nil {
                caption("None: git, branch, touched repos and PR watch stay off for this agent's tabs.")
            } else {
                caption("Runs `git` and `gh` next to the agent: `\(Self.oneLine(config.exec!)) git --version`.")
            }
        }
        .accessibilityIdentifier("agent-exec-derived")
    }

    /// What the last Test connection on this agent found.
    @ViewBuilder private func testResult(_ config: AcpAgentConfig) -> some View {
        switch model.acpConnectionTests[config.id] {
        case let .connected(record)?:
            VStack(alignment: .leading, spacing: 6) {
                Label("Connected to \(record.negotiated.agentName ?? "the agent")"
                        + (record.negotiated.agentVersion.map { " \($0)" } ?? ""),
                      systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.checkGreen)
                FlowLayout(spacing: 5) {
                    ForEach(Self.flags(record.negotiated), id: \.0) { flag in chip(flag.0, on: flag.1) }
                    chip("git", on: record.git == true)
                    chip("gh", on: record.gh == true)
                    chip("gh logged in", on: record.ghAuthed == true)
                }
                ForEach(AcpFeature.allCases, id: \.self) { feature in
                    if let reason = record.reason(feature) {
                        Text("\(Self.title(feature)): \(reason)")
                            .font(.system(size: 10.5)).foregroundStyle(Theme.secondaryText)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.chipBackground))
            .accessibilityIdentifier("agent-test-result")
        case let .failed(message, log)?:
            VStack(alignment: .leading, spacing: 5) {
                Label(message, systemImage: "xmark.octagon.fill")
                    .font(.system(size: 11.5)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Show Log in Finder") { NSWorkspace.shared.activateFileViewerSelecting([log]) }
                    .buttonStyle(.link).controlSize(.small)
            }
            .accessibilityIdentifier("agent-test-result")
        case nil:
            EmptyView()
        }
    }

    // MARK: - Actions

    private func edit(_ next: AcpAgentDraft, isNew: Bool) {
        draft = next
        draftIsNew = isNew
    }

    /// A copy under a free name ("<name> copy", "<name> copy 2", …), opened in the form.
    private func duplicate(_ agent: AcpAgentConfig) {
        var copy = agent
        copy.id = UUID()
        var name = "\(agent.name) copy"
        var n = 2
        while agents.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            name = "\(agent.name) copy \(n)"
            n += 1
        }
        copy.name = name
        edit(AcpAgentDraft(copy), isNew: true)
    }

    private func save(_ config: AcpAgentConfig) {
        guard draft?.validationErrors.isEmpty != false,
              config.validationErrors(among: agents, openTabAgents: openTabAgents).isEmpty else { return }
        if let i = agents.firstIndex(where: { $0.id == config.id }) {
            agents[i] = config
        } else {
            agents.append(config)
        }
        model.acpAgentStore.save(agents)
        draft = nil
    }

    /// Refused while a tab is open on the agent (R14, decided in Core); otherwise confirm.
    private func requestDelete(_ agent: AcpAgentConfig) {
        if let reason = agent.deletionError(openTabAgents: openTabAgents) {
            deleteRefused = (agent.id, reason)
        } else {
            deleteRefused = nil
            confirmingDelete = agent
        }
    }

    private func delete(_ agent: AcpAgentConfig) {
        // Re-checked: a tab may have opened on it while the sheet was up.
        guard agent.deletionError(openTabAgents: openTabAgents) == nil else { return requestDelete(agent) }
        agents.removeAll { $0.id == agent.id }
        model.acpAgentStore.save(agents)
        if draft?.id == agent.id { draft = nil }
    }

    private func test(_ config: AcpAgentConfig) {
        testing = true
        Task {
            _ = await model.testACPConnection(config)
            testing = false
        }
    }

    // MARK: - Pieces

    /// The agents named by open tabs — a rename (R12) or delete (R14) of one is refused.
    private var openTabAgents: [String] {
        model.sessions.sessions.compactMap {
            if case let .acp(name) = $0.backend { return name }
            return nil
        }
    }

    /// Agents configured and the API server on: a container may reach the unauthenticated
    /// server, so the pane says so — at the list, and again in an open form.
    private var apiServerWarningShown: Bool { apiServerOn ?? model.config.features.apiServer }

    private func apiServerWarning(leading: CGFloat) -> some View {
        note("exclamationmark.shield.fill",
             "The API server on :\(model.apiServerPort ?? model.apiServerPreferredPort) has no "
                 + "authentication. A container may be able to reach it.", leading: leading)
            .accessibilityIdentifier("agent-api-warning")
    }

    private func binding(_ key: WritableKeyPath<AcpAgentDraft, String>) -> Binding<String> {
        Binding(get: { draft?[keyPath: key] ?? "" }, set: { draft?[keyPath: key] = $0 })
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Theme.secondaryText).frame(width: 96, alignment: .leading)
    }

    private func field(
        _ title: String, _ key: WritableKeyPath<AcpAgentDraft, String>, placeholder: String, id: String,
        mono: Bool = false
    ) -> some View {
        HStack(spacing: 10) {
            label(title)
            TextField(placeholder, text: binding(key))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: mono ? .monospaced : .default))
                .accessibilityIdentifier(id)
        }
    }

    /// An argv list: one single-line field per argument, up/down to reorder, − to remove, and
    /// Add argument to append a row (focused).
    private func argList(
        _ title: String, _ key: WritableKeyPath<AcpAgentDraft, AcpArgList>, _ list: AcpArgList,
        placeholders: [String], id: String
    ) -> some View {
        rowList(title, key, list, add: "Add argument", id: id, reorderable: true) { text, index, row in
            TextField(index < placeholders.count ? placeholders[index] : "", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .focused($focusedRow, equals: RowFocus(row: row, field: 0))
                .accessibilityIdentifier("\(id)-row-\(index)")
        }
    }

    /// A key/value list: a key field and a value field side by side, − to remove, and an Add
    /// button that appends a row and focuses its key.
    private func pairList(
        _ title: String, _ key: WritableKeyPath<AcpAgentDraft, AcpPairList>, _ list: AcpPairList,
        placeholder: (key: String, value: String), add: String, id: String
    ) -> some View {
        rowList(title, key, list, add: add, id: id, reorderable: false) { pair, index, row in
            HStack(spacing: 6) {
                TextField(index == 0 ? placeholder.key : "", text: pair.key)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 150)
                    .focused($focusedRow, equals: RowFocus(row: row, field: 0))
                    .accessibilityIdentifier("\(id)-key-\(index)")
                Text("=").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.secondaryText)
                TextField(index == 0 ? placeholder.value : "", text: pair.value)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .focused($focusedRow, equals: RowFocus(row: row, field: 1))
                    .accessibilityIdentifier("\(id)-value-\(index)")
            }
        }
    }

    /// The one list editor behind all four lists: the label, a row per entry (its fields, then
    /// up/down when the order matters, then −), and the Add button under them.
    private func rowList<Item, Fields: View>(
        _ title: String, _ key: WritableKeyPath<AcpAgentDraft, AcpRowList<Item>>, _ list: AcpRowList<Item>,
        add: String, id: String, reorderable: Bool,
        @ViewBuilder fields: @escaping (Binding<Item>, Int, UUID) -> Fields
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            label(title).padding(.top, 4)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(list.rows.enumerated()), id: \.element.id) { index, row in
                    HStack(spacing: 4) {
                        fields(Binding(get: { draft?[keyPath: key][row.id] ?? row.item },
                                       set: { draft?[keyPath: key][row.id] = $0 }),
                               index, row.id)
                        if reorderable {
                            rowButton("chevron.up", "Move up", id: "\(id)-up-\(index)",
                                      disabled: !list.canMove(row.id, by: -1)) {
                                draft?[keyPath: key].move(row.id, by: -1)
                            }
                            rowButton("chevron.down", "Move down", id: "\(id)-down-\(index)",
                                      disabled: !list.canMove(row.id, by: 1)) {
                                draft?[keyPath: key].move(row.id, by: 1)
                            }
                        }
                        rowButton("minus.circle", "Remove", id: "\(id)-remove-\(index)", disabled: list.isBlank) {
                            draft?[keyPath: key].remove(row.id)
                        }
                    }
                }
                Button {
                    if let row = draft?[keyPath: key].append() { focusedRow = RowFocus(row: row, field: 0) }
                } label: {
                    Label(add, systemImage: "plus").font(.system(size: 11.5))
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("\(id)-add")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(id)
        }
    }

    private func rowButton(
        _ icon: String, _ help: String, id: String, disabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 11, weight: .medium)).frame(width: 18, height: 20)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Theme.secondaryText)
        .opacity(disabled ? 0.35 : 1)  // the explicit style would otherwise hide the disabled look
        .disabled(disabled)
        .help(help)
        .accessibilityIdentifier(id)
    }

    private func caption(_ text: String) -> some View {
        Text(.init(text)).font(.system(size: 10.5)).foregroundStyle(Theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 106)
    }

    private func note(_ icon: String, _ text: String, leading: CGFloat = 106) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 11)).foregroundStyle(Theme.busyAmber)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, leading)
    }

    private func chip(_ text: String, on: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: on ? "checkmark" : "minus").font(.system(size: 8, weight: .bold))
            Text(text).font(.system(size: 10.5))
        }
        .foregroundStyle(on ? Theme.primaryText : Theme.secondaryText)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(Theme.contentBackground))
        .opacity(on ? 1 : 0.7)
    }

    static func flags(_ c: AcpCapabilities) -> [(String, Bool)] {
        [("load", c.loadSession), ("resume", c.resume), ("fork", c.fork), ("list", c.list),
         ("close", c.close), ("HTTP MCP", c.mcpHTTP), ("steering", c.steering)]
    }

    static func title(_ feature: AcpFeature) -> String {
        switch feature {
        case .branch: "Branch"
        case .touchedRepos: "Touched repos"
        case .prWatch: "PR watch"
        case .fork: "Fork"
        case .importSessions: "Import sessions"
        case .bridgeTools: "Bridge tools"
        case .steering: "Steering"
        }
    }

    static func oneLine(_ c: AcpCommand) -> String { ([c.command] + c.args).joined(separator: " ") }
}
