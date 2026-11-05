import AppKit
import SwiftUI
import AdmiralCore

/// `-probeAgentsUI <dir>`: the ACP UI drawn into PNGs from a fixture, dark and light, with no
/// agent running — Settings → Agents (empty, one valid agent with a Test connection result, one
/// passing the ignored `--dangerously-skip-permissions` with the API server on), and ACP tabs
/// registered without a process: one ready (a permission card, a queue, features off with
/// their reasons), one whose agent failed to connect (the reason and Retry). Writes
/// `<dir>/proof.txt` and exits 1 on any FAIL.
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
            finish()
        }
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
