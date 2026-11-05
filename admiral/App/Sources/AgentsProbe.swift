import AppKit
import SwiftUI
import AdmiralCore

/// `-probeAgentsUI <dir>`: the ACP UI drawn into PNGs from a fixture, dark and light, with no
/// agent running — Settings → Agents (empty, one valid agent with a Test connection result, one
/// passing the ignored `--dangerously-skip-permissions` with the API server on), and ACP tabs
/// registered without a process: one ready (a permission card, a queue, features off with
/// their reasons), one whose agent failed to connect (the reason and Retry). Then where an agent
/// runs and its starting options (a This Mac form with no Exec / Bridge URL, an Elsewhere one,
/// both with pickers from a fixture catalog), one tab's composer (option chips, the `/` menu, a
/// command's hint, the `@` list from fixture files) and its chat's tool cards (an output, a diff,
/// a running call with its live output). Writes `<dir>/proof.txt` and exits 1 on any FAIL.
///
/// It saves agents and writes chat fixtures, so it refuses to run without an isolated
/// `ADMIRAL_SUPPORT_DIR` (use a unique `ADMIRAL_PROFILE` too, as for every probe).
extension AppModel {
    func runAgentsUIProbe(dir: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            var lines: [String] = []
            func check(_ name: String, _ ok: Bool, _ detail: String) {
                lines.append("\(ok ? "PASS" : "FAIL")  \(name) — \(detail)")
            }
            func finish() -> Never {
                let failed = lines.contains { $0.hasPrefix("FAIL") }
                lines.insert("agents-ui: \(failed ? "FAIL" : "PASS")", at: 0)
                try? (lines.joined(separator: "\n") + "\n")
                    .write(toFile: dir + "/proof.txt", atomically: true, encoding: .utf8)
                exit(failed ? 1 : 0)
            }
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            guard ProcessInfo.processInfo.environment["ADMIRAL_SUPPORT_DIR"].map({ !$0.isEmpty }) == true else {
                check("isolated", false, "ADMIRAL_SUPPORT_DIR is not set; refusing to touch the real config")
                finish()
            }
            func draw<V: View>(_ name: String, _ view: V, _ size: NSSize, dark: Bool) async {
                let file = name + (dark ? "" : "-light") + ".png"
                let ok = await self.renderOffscreen(view, size: size, dark: dark, to: dir + "/" + file)
                check("\(name) drawn\(dark ? "" : " (light)")", ok, file)
            }
            func settings(_ editing: AcpAgentConfig?, apiServerOn: Bool = false) -> some View {
                AgentsSettingsView(editing: editing, apiServerOn: apiServerOn)
                    .frame(width: 640).background(Theme.surface)
            }

            // Settings → Agents.
            let valid = AcpAgentConfig(
                name: "Claude Code (container)",
                launch: AcpCommand(command: "docker", args: [
                    "exec", "-i", "-w", "/path/in/container", "-e", "HOME=/home/node", "my-container",
                    "npx", "-y", "@agentclientprotocol/claude-agent-acp@0.100.0"]),
                env: ["DOCKER_CONFIG": "/path/to/docker-config", "NAME": "value"], cwd: "/path/in/container",
                workspace: .elsewhere(exec: AcpCommand(command: "docker", args: [
                    "exec", "-w", "/path/in/container", "-e", "HOME=/home/node", "my-container"])),
                defaultConfigOptions: ["model": "opus"], mcpCallbackURL: "http://host.docker.internal:4142")
            let legacy = AcpAgentConfig(
                name: "JetBrains import",
                launch: AcpCommand(command: "docker", args: [
                    "exec", "-i", "other-container", "claude-agent-acp", "--dangerously-skip-permissions"]),
                env: ["DOCKER_HOST": "unix:///var/run/docker.sock"], cwd: "/path/in/container",
                workspace: .elsewhere(exec: nil), mcpCallbackURL: "http://host.docker.internal:4142")
            self.acpAgentStore.save([])
            let collapsed = self.sidebarCollapsed
            for dark in [true, false] {
                self.acpAgentStore.save([])
                await draw("agents-empty", settings(nil), NSSize(width: 640, height: 300), dark: dark)

                self.acpAgentStore.save([valid])
                self.acpConnectionTests[valid.id] = .connected(Self.probeRecord(fork: true, list: true, git: true))
                await draw("agents-valid", settings(valid), NSSize(width: 640, height: 1180), dark: dark)

                // A new agent: This Mac, every list empty, one placeholder row each.
                await draw("agents-new", AgentsSettingsView(draft: AcpAgentDraft.new(), isNew: true)
                    .frame(width: 640).background(Theme.surface), NSSize(width: 640, height: 900), dark: dark)

                // A key typed twice: refused with a message, never a silent last-wins.
                var twice = AcpAgentDraft(valid)
                let extra = twice.env.append()
                twice.env[extra] = AcpPair(key: "NAME", value: "other")
                await draw("agents-duplicate-key", AgentsSettingsView(draft: twice, isNew: false)
                    .frame(width: 640).background(Theme.surface), NSSize(width: 640, height: 1260), dark: dark)

                // With the API server feature on (the warning), drawn without starting a server.
                self.acpAgentStore.save([valid, legacy])
                await draw("agents-ignored-flag", settings(legacy, apiServerOn: true),
                           NSSize(width: 640, height: 1180), dark: dark)
                // The list alone, form closed: the warning stands at the list (both on).
                await draw("agents-api-warning", settings(nil, apiServerOn: true),
                           NSSize(width: 640, height: 360), dark: dark)
            }

            // The checks behind what was drawn, from the same Core the view reads.
            var dup = legacy
            dup.id = UUID()
            dup.name = "claude code (container)"
            check("a duplicate name is refused (any case)",
                  dup.validationErrors(among: [valid, legacy]).contains { $0.contains("already exists") },
                  dup.validationErrors(among: [valid, legacy]).joined(separator: "; "))
            var twice = AcpAgentDraft(valid)
            twice.env[twice.env.append()] = AcpPair(key: "NAME", value: "other")
            check("a duplicate env key is refused", twice.validationErrors.count == 1,
                  twice.validationErrors.joined(separator: "; "))
            check("the rows round-trip the config", AcpAgentDraft(valid).config == valid,
                  "args \(AcpAgentDraft(valid).args.rows.count) rows")
            check("the ignored flag is detected",
                  legacy.passesIgnoredSkipPermissionsFlag && !valid.passesIgnoredSkipPermissionsFlag, "legacy only")
            check("the exec runs next to the agent",
                  valid.execRunnerCommand == AcpCommand(command: "docker", args: [
                      "exec", "-w", "/path/in/container", "-e", "HOME=/home/node", "my-container"]),
                  valid.execRunnerCommand.map { ([$0.command] + $0.args).joined(separator: " ") } ?? "nil")
            check("a new agent runs on this Mac", AcpAgentDraft.new().workspace == .thisMac
                    && AcpAgentDraft.new().config.mcpCallbackURL == "http://127.0.0.1:4142", "draft.new()")

            // ACP tabs, registered without a process. Their agent is not in the store, so no
            // timer ever runs its exec.
            let fixture = self.seedACPTabsForUIProbe()
            let logURL = self.acpLogURL(for: fixture.ready)
            if let logURL {
                AcpLog.append(#"acp: -> {"id":1,"jsonrpc":"2.0","method":"initialize","params":{"protocolVersion":1}}"#,
                              to: logURL)
                AcpLog.append(#"acp: <- {"id":1,"jsonrpc":"2.0","result":{"agentInfo":{"name":"claude-agent-acp"}}}"#,
                              to: logURL)
                AcpLog.append("[claude-agent-acp] session s1 ready", to: logURL)
            }
            // R12: the tabs' agent, being renamed while they are open — refused, and said so.
            let containerBox = AcpAgentConfig(
                name: "Container box",
                launch: AcpCommand(command: "docker", args: ["exec", "-i", "my-container", "agent"]),
                cwd: "/path/in/container", workspace: .elsewhere(exec: nil),
                mcpCallbackURL: "http://host.docker.internal:4142")
            var renamed = containerBox
            renamed.name = "Container box (renamed)"
            let openNames = self.sessions.sessions.compactMap { s -> String? in
                if case let .acp(name) = s.backend { return name }
                return nil
            }
            check("renaming an agent with open tabs is refused",
                  renamed.validationErrors(among: [containerBox], openTabAgents: openNames)
                      == [AcpAgentConfig.renameWithOpenTabs], openNames.joined(separator: ", "))
            check("deleting an agent with open tabs is refused",
                  containerBox.deletionError(openTabAgents: openNames) == AcpAgentConfig.deleteWithOpenTabs,
                  openNames.joined(separator: ", "))
            for dark in [true, false] {
                self.acpAgentStore.save([containerBox])
                await draw("agents-rename-blocked", settings(renamed), NSSize(width: 640, height: 1180), dark: dark)
            }
            for dark in [true, false] {
                self.sidebarCollapsed = false
                await draw("sidebar", SidebarView(), NSSize(width: 272, height: 360), dark: dark)
                self.sidebarCollapsed = collapsed
                self.selectTerminal(fixture.ready.id)
                await draw("tab-ready", DetailView(), NSSize(width: 900, height: 620), dark: dark)
                await draw("footprint-ready", TouchedReposPanel(), NSSize(width: 280, height: 620), dark: dark)
                self.selectTerminal(fixture.failed.id)
                await draw("tab-failed", DetailView(), NSSize(width: 900, height: 620), dark: dark)
                await draw("footprint-failed", TouchedReposPanel(), NSSize(width: 280, height: 620), dark: dark)
                if let logURL {
                    await draw("acp-log", AcpLogView(title: fixture.ready.displayTitle, url: logURL),
                               NSSize(width: 860, height: 560), dark: dark)
                }
            }

            self.selectTerminal(fixture.ready.id)
            check("an ACP tab is Chat only", self.viewMode(for: fixture.ready) == .chat, "viewMode")
            check("⌘J is off on an ACP tab", !self.selectedCanToggleView, "selectedCanToggleView")
            check("fork is off with the record's reason",
                  self.forkDisabledReason(fixture.ready) == "The agent doesn't support fork",
                  self.forkDisabledReason(fixture.ready) ?? "nil")
            check("the permission card is open", self.sessions.chats[fixture.ready.id]?.isWaiting == true
                    || ChatHistory.live(base: self.sessions.supportDir, session: fixture.ready.claudeSessionID ?? "",
                                        transcriptPath: fixture.ready.transcriptPath).isWaiting,
                  "needs card")

            // Workspace, starting options, composer pickers and tool cards (one tab on a This Mac agent).
            await self.drawAcpChatImprovements(check: check) { name, view, size, dark, inspect in
                let file = name + (dark ? "" : "-light") + ".png"
                let ok = await self.renderOffscreen(view, size: size, dark: dark, to: dir + "/" + file,
                                                    inspect: inspect)
                check("\(name) drawn\(dark ? "" : " (light)")", ok, file)
            }
            finish()
        }
    }

    /// The agent's catalog as Settings gets it: a mode and a model option.
    static let probeCatalog: [AcpConfigOption] = [
        AcpConfigOption(id: "mode", name: "Mode", description: "How the agent asks before acting",
                        category: "mode", currentValue: "default", values: [
                            AcpOptionValue(value: "default", name: "Default"),
                            AcpOptionValue(value: "acceptEdits", name: "Accept edits"),
                            AcpOptionValue(value: "plan", name: "Plan"),
                        ]),
        AcpConfigOption(id: "model", name: "Model", category: "model", currentValue: "default", values: [
            AcpOptionValue(value: "default", name: "Default (recommended)"),
            AcpOptionValue(value: "large", name: "Large model", group: "Other models"),
            AcpOptionValue(value: "small", name: "Small model", group: "Other models"),
        ]),
    ]

    /// The tab's options: the catalog, then as many more as a real agent sends (effort, two
    /// on/off toggles, a long-valued picker), so the composer's bottom row is drawn as crowded
    /// as it gets.
    static let probeTabOptions: [AcpConfigOption] = probeCatalog + [
        AcpConfigOption(id: "effort", name: "Effort", category: "thought_level", currentValue: "medium", values: [
            AcpOptionValue(value: "low", name: "Low"), AcpOptionValue(value: "medium", name: "Medium"),
            AcpOptionValue(value: "high", name: "High"),
        ]),
        AcpConfigOption(id: "fast", name: "Fast", category: "model_config", currentValue: "off", values: [
            AcpOptionValue(value: "on", name: "On"), AcpOptionValue(value: "off", name: "Off"),
        ]),
        AcpConfigOption(id: "verbose", name: "Verbose", category: "model_config", currentValue: "off", values: [
            AcpOptionValue(value: "on", name: "On"), AcpOptionValue(value: "off", name: "Off"),
        ]),
        AcpConfigOption(id: "agent", name: "Agent", currentValue: "team:reviewer", values: [
            AcpOptionValue(value: "default", name: "Default"),
            AcpOptionValue(value: "team:reviewer", name: "team:reviewer"),
        ]),
    ]

    /// Every accessibility identifier under `root` — what the probe asserts a drawn view holds.
    static func accessibilityIdentifiers(_ root: NSView) -> Set<String> {
        var out: Set<String> = []
        var stack: [Any] = [root]
        var visited = 0
        while let element = stack.popLast(), visited < 20_000 {
            visited += 1
            guard let node = element as? NSAccessibilityProtocol else { continue }
            if let id = node.accessibilityIdentifier(), !id.isEmpty { out.insert(id) }
            stack.append(contentsOf: node.accessibilityChildren() ?? [])
        }
        return out
    }

    /// Draws one PNG (name, view, size, dark), handing the laid-out view to the last closure.
    typealias ProbeDraw = (String, AnyView, NSSize, Bool, @escaping (NSView) -> Void) async -> Void

    /// The agent workspace, starting options, composer pickers and tool cards, with their checks.
    func drawAcpChatImprovements(check: (String, Bool, String) -> Void, draw: ProbeDraw) async {
        let catalog = Self.probeCatalog
        let thisMac = AcpAgentConfig(
            name: "Local agent", launch: AcpCommand(command: "npx", args: ["-y", "<agent-package>@<version>"]),
            cwd: "/path/to/project", workspace: .thisMac, defaultConfigOptions: ["mode": "plan"],
            mcpCallbackURL: "http://127.0.0.1:4142")
        let elsewhere = AcpAgentConfig(
            name: "Agent elsewhere", launch: AcpCommand(command: "ssh", args: ["my-host", "agent-command"]),
            cwd: "/path/on/host", workspace: .elsewhere(exec: AcpCommand(command: "ssh", args: ["my-host"])),
            defaultConfigOptions: ["model": "large", "effort": "high"],
            mcpCallbackURL: "http://127.0.0.1:4142")
        acpOptionCatalogStore.save(catalog, agentID: thisMac.id)
        acpOptionCatalogStore.save(catalog, agentID: elsewhere.id)
        acpAgentStore.save([thisMac, elsewhere])

        var formIDs: [String: Set<String>] = [:]
        for dark in [true, false] {
            for (name, agent) in [("agents-this-mac", thisMac), ("agents-elsewhere-options", elsewhere)] {
                let view = AgentsSettingsView(draft: AcpAgentDraft(agent, catalog: catalog), isNew: false)
                    .frame(width: 640).background(Theme.surface)
                await draw(name, AnyView(view), NSSize(width: 640, height: 1100), dark) { host in
                    formIDs[name] = Self.accessibilityIdentifiers(host)
                }
            }
        }
        // The drawn forms' accessibility tree holds their text fields and segmented picker (not
        // their containers or menu pickers): Bridge URL is a text field, inside the same
        // Elsewhere-only branch as Exec, so its absence on This Mac is that whole branch's.
        let mac = formIDs["agents-this-mac"] ?? []
        let other = formIDs["agents-elsewhere-options"] ?? []
        check("the This Mac form is read (control)", mac.contains("agent-workspace"),
              mac.sorted().joined(separator: " "))
        check("the This Mac form has no Exec or Bridge URL", !mac.contains("agent-callback"),
              "no agent-callback")
        check("the Elsewhere form has Exec and Bridge URL (control)", other.contains("agent-callback"),
              other.sorted().joined(separator: " "))
        let macDraft = AcpAgentDraft(thisMac, catalog: catalog)
        check("This Mac starts on its catalog's pick",
              macDraft.startingOptions == ["mode": "plan"] && macDraft.catalog.map(\.id) == ["mode", "model"],
              macDraft.startingOptions.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
        let otherKeys = AcpAgentDraft(elsewhere, catalog: catalog).configOptions.rows.map(\.item.key)
            .filter { !$0.isEmpty }
        check("a key outside the catalog stays a typed row", otherKeys == ["effort"],
              otherKeys.joined(separator: ", "))

        // One tab on an agent the store doesn't hold (so no runner ever runs git): its options,
        // its commands, a failed command, a finished edit, and a command still running.
        let base = sessions.supportDir
        let sid = UUID().uuidString.lowercased()
        var tab = AgentSession(
            callsign: "tidy-api", agentType: .acp(agentName: "Probe agent"), cwd: "/path/to/project",
            claudeSessionID: sid, transcriptPath: TranscriptMirror.url(base: base, session: sid).path,
            status: .busy, avatarColorHex: "#3FB68B", avatarSymbol: "laptopcomputer")
        tab.backend = .acp(agentName: "Probe agent")
        tab.acpSessionID = "acp-tidy-api"
        tab.acpCapabilities = Self.probeRecord(fork: true, list: true, git: true)
        tab.acpConfigOptions = Self.probeTabOptions
        tab.acpCommands = [
            AcpCommandInfo(name: "review", description: "Review a pull request", hint: "<pr-number>"),
            AcpCommandInfo(name: "compact", description: "Summarize the conversation to free context"),
            AcpCommandInfo(name: "init", description: "Write a guide for this project"),
        ]
        tab.acpLiveOutput = ["t3": "  PASS  src/api/users.test.ts\n  PASS  src/api/orders.test.ts\n"
                             + "  RUNS  src/api/auth.test.ts\n"]
        let mirror = TranscriptMirror(
            url: TranscriptMirror.url(base: base, session: sid), sessionID: sid, cwd: "/path/to/project")
        mirror.userPrompt("The users endpoint returns 500 for an empty name. Fix it and run the tests.")
        mirror.apply(.toolCall(id: "t1", title: "npm test -- users", kind: "execute", status: "pending",
                               rawInput: .object(["command": .string("npm test -- users")]), locations: []))
        mirror.apply(.toolCallUpdate(id: "t1", status: nil, content: nil, locations: [],
                                     items: [.terminal(id: "t1")]))
        mirror.apply(.terminalOutput(toolCallID: "t1", data: [
            "> api@1.0.0 test", "> jest users", "",
            "  FAIL  src/api/users.test.ts", "    \u{2715} rejects an empty name (12 ms)",
            "      Expected status 400, received 500", "", "Tests: 1 failed, 7 passed, 8 total",
        ].joined(separator: "\n")))
        mirror.apply(.toolCallUpdate(id: "t1", status: "failed", content: nil, locations: []))
        mirror.apply(.agentMessage("The handler calls `name.trim()` before checking it exists. Guarding it."))
        let path = "/path/to/project/src/api/users.ts"
        mirror.apply(.toolCall(id: "t2", title: "Edit src/api/users.ts", kind: "edit", status: "pending",
                               rawInput: .object(["file_path": .string(path)]), locations: [path]))
        mirror.apply(.toolCallUpdate(id: "t2", status: nil, content: nil, locations: [], items: [
            .diff(path: path,
                  oldText: "export function createUser(req, res) {\n  const name = req.body.name.trim();\n"
                      + "  return save({ name });\n}\n",
                  newText: "export function createUser(req, res) {\n  const name = req.body.name?.trim();\n"
                      + "  if (!name) return res.status(400).send('name is required');\n"
                      + "  return save({ name });\n}\n"),
        ]))
        mirror.apply(.toolCallUpdate(id: "t2", status: "completed", content: nil, locations: []))
        mirror.apply(.toolCall(id: "t3", title: "npm test", kind: "execute", status: "in_progress",
                               rawInput: .object(["command": .string("npm test")]), locations: []))
        mirror.endTurn()
        sessions.register(tab, handle: nil)
        sessions.refreshChat(tab.id)
        let live = sessions.sessions.first { $0.id == tab.id } ?? tab

        let read = ChatHistory.live(base: base, session: sid, transcriptPath: tab.transcriptPath, tools: true)
        let tools = read.items.compactMap { item -> ChatTool? in
            if case let .tool(_, tool, _) = item { return tool }
            return nil
        }
        let shape = tools.map { tool -> String in
            let detail = switch tool.detail {
            case .none: "none"
            case .output: "output"
            case .diff: "diff"
            }
            return "\(tool.name):\(tool.status.rawValue):\(detail)"
        }
        check("the mirror reads back as three tool cards",
              shape == ["Bash:failed:output", "Edit:completed:diff", "Bash:running:none"],
              shape.joined(separator: ", "))

        func composer(_ text: String, files: [String]? = nil, width: CGFloat = 820) -> AnyView {
            AnyView(VStack(spacing: 0) {
                Spacer(minLength: 0)
                ChatComposer(session: live, isWorking: false, initialText: text, probeFiles: files)
            }
            .frame(width: width, height: 340).background(Theme.surface))
        }
        let files = ["src/api/users.ts", "src/api/users.test.ts", "src/api/orders.ts", "src/server.ts",
                     "README.md"]
        var chips: Set<String> = []
        var toolIDs: Set<String> = []
        for dark in [true, false] {
            await draw("composer-chips", composer(""), NSSize(width: 820, height: 340), dark) { host in
                chips = Self.accessibilityIdentifiers(host)
            }
            await draw("composer-chips-narrow", composer("", width: 560), NSSize(width: 560, height: 340), dark) { _ in }
            await draw("composer-slash", composer("/"), NSSize(width: 820, height: 340), dark) { _ in }
            await draw("composer-slash-hint", composer("/review "), NSSize(width: 820, height: 340), dark) { _ in }
            await draw("composer-files", composer("see @src", files: files),
                       NSSize(width: 820, height: 340), dark) { _ in }
            selectTerminal(tab.id)
            await draw("tab-tools", AnyView(DetailView().environment(\.toolCardsStartExpanded, true)),
                       NSSize(width: 900, height: 900), dark) { host in
                toolIDs = Self.accessibilityIdentifiers(host)
            }
            await draw("tab-tools-collapsed", AnyView(DetailView()), NSSize(width: 900, height: 620), dark) { _ in }
        }
        check("the composer has a chip for mode and for model",
              chips.isSuperset(of: ["acp-option-mode", "acp-option-model"]),
              chips.filter { $0.hasPrefix("acp-option") }.sorted().joined(separator: ", "))
        // The menus and cards are not in the tree (no text field or control of their own), so
        // what they show is checked from the Core they draw, and by eye in the PNGs.
        let slash = SlashCommandPicker.query(in: "/")
            .map { SlashCommandPicker.candidates($0, commands: live.acpCommands) }
        check("\"/\" opens the command menu with every command",
              slash?.map(\.name) == ["review", "compact", "init"],
              slash?.map(\.name).joined(separator: ", ") ?? "closed")
        check("a whole \"/review \" closes the menu (the hint shows instead)",
              SlashCommandPicker.query(in: "/review ") == nil
                  && live.acpCommands.first { SlashCommandPicker.insert($0) == "/review " }?.hint == "<pr-number>",
              "hint <pr-number>")
        let matches = FileMentionPicker.query(in: "see @src")
            .map { FileMentionPicker.candidates($0.partial, files: files) }
        check("\"@src\" lists the matching files", matches == Array(files.prefix(4)),
              matches?.joined(separator: ", ") ?? "closed")
        let tail = ChatTool.tail(live.acpLiveOutput["t3"] ?? "", lines: 6)
        check("the running call's live output is its tail", tail.hasSuffix("RUNS  src/api/auth.test.ts"),
              tail.replacingOccurrences(of: "\n", with: " | "))
        check("the chat view is drawn (control)", toolIDs.contains("chat-input"),
              toolIDs.sorted().joined(separator: ", "))
    }

    /// A record as a tab would hold it once `initialize` and the probes answered.
    static func probeRecord(fork: Bool, list: Bool, git: Bool?) -> AcpCapabilityRecord {
        var caps: [String: JSONValue] = [:]
        if fork { caps["fork"] = .object([:]) }
        if list { caps["list"] = .object([:]) }
        caps["resume"] = .object([:])
        let initialize: JSONValue = .object([
            "agentInfo": .object(["name": .string("claude-agent-acp"), "version": .string("0.100.0")]),
            "agentCapabilities": .object([
                "loadSession": .bool(true), "sessionCapabilities": .object(caps),
                "mcpCapabilities": .object(["http": .bool(true)]),
            ]),
        ])
        return AcpCapabilityRecord(
            negotiated: AcpCapabilities(initializeResult: initialize), hasExec: git != nil,
            bridgeRunning: false, git: git, gh: git == true ? false : nil, ghAuthed: git == true ? false : nil)
    }

    /// Two ACP tabs on "Container box": `ready` mid-turn on a permission, with a reply in its chat
    /// and one message queued; `failed`, whose container was stopped.
    func seedACPTabsForUIProbe() -> (ready: AgentSession, failed: AgentSession) {
        let base = sessions.supportDir
        func tab(_ name: String, color: String, status: SessionStatus) -> AgentSession {
            let sid = UUID().uuidString.lowercased()
            var s = AgentSession(
                callsign: name, agentType: .acp(agentName: "Container box"), cwd: "/path/in/container",
                claudeSessionID: sid,
                transcriptPath: TranscriptMirror.url(base: base, session: sid).path, status: status,
                avatarColorHex: color, avatarSymbol: "shippingbox")
            s.backend = .acp(agentName: "Container box")
            s.acpSessionID = "acp-\(name)"
            return s
        }
        var ready = tab("fix-login", color: "#5B8CFF", status: .busy)
        ready.acpCapabilities = Self.probeRecord(fork: false, list: true, git: true)
        ready.acpQueued = ["Also update the changelog when you're done."]
        let sid = ready.claudeSessionID ?? ""
        let mirror = TranscriptMirror(
            url: TranscriptMirror.url(base: base, session: sid), sessionID: sid, cwd: "/path/in/container")
        mirror.userPrompt("The login form rejects valid emails with a plus sign. Fix it and run the tests.")
        mirror.apply(.agentMessage("The validator's regex doesn't allow `+` in the local part. "
                                   + "I've widened it and added a test case; running the suite now."))
        mirror.endTurn()
        ChatLedger.append(ChatEvent(ts: SessionManager.acpChatTimestamp(Date().addingTimeInterval(1)),
                                    kind: .needs, text: "Run npm test -- --watch=false"),
                          base: base, session: sid)

        var failed = tab("nightly-db", color: "#E8912D", status: .shell)
        failed.connectError = "the agent exited before it started: Error response from daemon: "
            + "container my-container is not running"
        for session in [ready, failed] { sessions.register(session, handle: nil) }
        sessions.refreshChat(ready.id)
        return (ready, failed)
    }
}
