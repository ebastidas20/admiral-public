import Darwin
import XCTest
@testable import AdmiralCore

/// End-to-end checks of ACP tabs against a REAL agent: Claude Code's ACP adapter inside a
/// running Docker container, reached with `docker exec -i`. Opt-in — every test skips unless
/// `ADMIRAL_ACP_E2E=1`, so the normal `swift test` stays fast and offline.
///
/// ```
/// ADMIRAL_ACP_E2E=1 swift test --filter AcpEndToEndTests
/// ```
///
/// `ADMIRAL_ACP_E2E_CONTAINER` names the container (default `ppt-claude-1`). The tests drive
/// the real code paths — `ProcessAcpTransport`, `SessionManager.commissionACP`,
/// `testACPConnection`, `importACPSessions`, fork, restore, reload — with a temp support dir
/// and an isolated `UserDefaults` suite. Nothing outside the temp dir is touched on the Mac;
/// in the container, the only thing created is a throwaway git repo under `/tmp`, removed in
/// tearDown (the agent's own session files are the agent's). Prompts are cheap and harmless.
///
/// The session bridge listener lives in the App target, so the lifecycle test serves
/// `SessionMCPEndpoint` (the same routing and token check) from a small loopback listener
/// of its own, on 127.0.0.1:4142 when free — the container reaches it as
/// `host.docker.internal`.
@MainActor
final class AcpEndToEndTests: XCTestCase {
    private static let env = ProcessInfo.processInfo.environment
    private static let container = env["ADMIRAL_ACP_E2E_CONTAINER"] ?? "ppt-claude-1"
    private static let package = "@agentclientprotocol/claude-agent-acp@0.100.0"

    private var base: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private var manager: SessionManager!
    private var bridge: BridgeCore!
    private var listener: LoopbackTestListener?
    /// The throwaway repo inside the container (removed in tearDown).
    private var repoDir: String?
    private var results: [(line: String, verdict: String, detail: String)] = []

    override func setUp() async throws {
        try await super.setUp()
        guard Self.env["ADMIRAL_ACP_E2E"] == "1" else {
            throw XCTSkip("ACP end-to-end tests run only with ADMIRAL_ACP_E2E=1 (they need \(Self.container))")
        }
        base = FileManager.default.temporaryDirectory.appendingPathComponent("acp-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        suite = "acp-e2e-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        manager = makeManager()
    }

    override func tearDown() async throws {
        manager?.terminateAll()
        listener?.stop()
        if let repoDir {
            _ = Self.sh(["docker", "exec", Self.container, "rm", "-rf", repoDir], timeout: 30)
        }
        if let suite { defaults?.removePersistentDomain(forName: suite) }
        // ADMIRAL_ACP_E2E_KEEP=1 keeps the support dir (mirrors, ACP logs) for a look afterwards.
        if let base {
            if Self.env["ADMIRAL_ACP_E2E_KEEP"] == "1" { print("E2E: kept support dir \(base.path)") }
            else { try? FileManager.default.removeItem(at: base) }
        }
        for r in results { print("E2E RESULT | \(r.line) | \(r.verdict) | \(r.detail)") }
        try await super.tearDown()
    }

    // MARK: - Setup helpers

    private func makeManager() -> SessionManager {
        let m = SessionManager(
            host: FakeTerminalHost(), claudeHome: base, executablePath: "/bin/echo",
            appearanceStore: SessionAppearanceStore(defaults: defaults),
            openSessionsStore: OpenSessionsStore(defaults: defaults), supportDir: base,
            touchedReposStore: TouchedReposStore(defaults: defaults))
        return m
    }

    private func agent(cwd: String = "/workspace", callbackPort: UInt16 = 4142) -> AcpAgentConfig {
        AcpAgentConfig(
            name: "ppt-e2e",
            launch: AcpCommand(command: "docker", args: [
                "exec", "-i", "-w", "/workspace", Self.container, "npx", "-y", Self.package,
            ]),
            cwd: cwd,
            workspace: .elsewhere(exec: AcpCommand(command: "docker", args: ["exec", "-w", "/workspace", Self.container])),
            defaultConfigOptions: ["mode": "bypassPermissions"],
            mcpCallbackURL: "http://host.docker.internal:\(callbackPort)")
    }

    /// Each launch's local `docker exec` client pid, by the tab's ACP log path — so the
    /// mid-turn kill hits that one tab's agent and no other.
    private var agentPIDByLog: [String: Int32] = [:]

    private func wire(_ m: SessionManager, agent: AcpAgentConfig, bridgeRunning: Bool) {
        m.acpAgents = { [agent] }
        m.sessionBridgeRunning = { bridgeRunning }
        m.acpTransportFactory = { [unowned self] config, log in
            let before = Set(Self.agentClientPIDs())
            let transport = try ProcessAcpTransport(command: config.launch, env: config.env, logURL: log)
            agentPIDByLog[log.path] = Set(Self.agentClientPIDs()).subtracting(before).first
            return transport
        }
    }

    /// Starts the session bridge listener for `m`: 4142 when free, else any port.
    private func startBridge(for m: SessionManager) -> UInt16? {
        let bridge = BridgeCore(manager: m, goalsStore: GoalsStore(base: base))
        self.bridge = bridge
        let endpoint = SessionMCPEndpoint(mcp: MCPServer(bridge: bridge), tokenIsLive: { [weak m] in
            m?.acpTokenIsLive($0) ?? false
        })
        let listener = LoopbackTestListener { await endpoint.handle($0) }
        self.listener = listener
        return listener.start(preferredPort: 4142) ?? listener.start(preferredPort: 0)
    }

    private func record(_ line: String, _ ok: Bool, _ detail: String) {
        results.append((line, ok ? "PASS" : "FAIL", detail))
        XCTAssertTrue(ok, "\(line): \(detail)")
    }

    // MARK: - Polling / reading helpers

    @discardableResult
    private func until(
        _ what: String, timeout: TimeInterval, _ condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                print("E2E: timed out after \(Int(timeout)) s waiting for \(what)")
                return false
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return true
    }

    private func session(_ id: UUID, in m: SessionManager? = nil) -> AgentSession? {
        (m ?? manager).sessions.first { $0.id == id }
    }

    /// A file's lines — with JSON's escaped `\/` put back, so a traced `session/prompt` is greppable.
    private static func lines(_ url: URL) -> [String] {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
            .replacingOccurrences(of: "\\/", with: "/")
            .split(separator: "\n").map(String.init)
    }

    private func mirrorURL(_ s: AgentSession) -> URL {
        TranscriptMirror.url(base: base, session: s.claudeSessionID!)
    }

    private func logURL(_ s: AgentSession) -> URL {
        SessionManager.acpLogURL(base: base, session: s.claudeSessionID!)
    }

    /// One mirror line: its type, its text (prompt or agent text), and tool uses.
    private struct MirrorLine {
        var type: String
        var text: String
        var tools: [(name: String, input: String)]
    }

    private static func mirrorLines(_ url: URL) -> [MirrorLine] {
        lines(url).compactMap { raw -> MirrorLine? in
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any],
                  let type = obj["type"] as? String,
                  let message = obj["message"] as? [String: Any] else { return nil }
            if let s = message["content"] as? String { return MirrorLine(type: type, text: s, tools: []) }
            var text = ""
            var tools: [(String, String)] = []
            for block in message["content"] as? [[String: Any]] ?? [] {
                switch block["type"] as? String {
                case "text": text += block["text"] as? String ?? ""
                case "tool_use":
                    let input = (try? JSONSerialization.data(withJSONObject: block["input"] ?? [:]))
                        .map { String(decoding: $0, as: UTF8.self) } ?? ""
                    tools.append((block["name"] as? String ?? "?", input))
                default: break
                }
            }
            return MirrorLine(type: type, text: text, tools: tools)
        }
    }

    /// What one turn produced.
    private struct Turn {
        var sawBusy = false
        var idle = false
        var reply = ""
        var users: [String] = []
        var tools: [(name: String, input: String)] = []
        var log: [String] = []
        var prompts: Int { log.filter { $0.hasPrefix("acp: -> ") && $0.contains("\"session/prompt\"") }.count }
        var permissionRequests: Int { log.filter { $0.contains("session/request_permission") }.count }
        var messageChunks: Int { log.filter { $0.contains("agent_message_chunk") }.count }
    }

    /// Sends `prompt` the way the Chat composer does, and waits for busy → idle (held idle for
    /// 3 s, so a hook follow-up that keeps the turn going is part of it). `during` runs while
    /// the turn is in flight; it gets the mirror lines seen so far and returns true once done.
    private func turn(
        _ id: UUID, _ prompt: String, in m: SessionManager? = nil, timeout: TimeInterval = 300,
        during: (([MirrorLine]) async -> Bool)? = nil
    ) async -> Turn {
        let m = m ?? manager!
        let s = session(id, in: m)!
        let mirrorStart = Self.mirrorLines(mirrorURL(s)).count
        let logStart = Self.lines(logURL(s)).count
        var t = Turn()
        XCTAssertTrue(m.sendTyped(id, text: prompt), "sendTyped refused")
        let deadline = Date().addingTimeInterval(timeout)
        var duringDone = during == nil
        var idleSince: Date?
        while Date() < deadline {
            let status = session(id, in: m)?.status
            if status == .busy { t.sawBusy = true; idleSince = nil }
            if !duringDone, let during {
                duringDone = await during(Array(Self.mirrorLines(mirrorURL(s)).dropFirst(mirrorStart)))
            }
            if t.sawBusy, status == .idle {
                idleSince = idleSince ?? Date()
                if Date().timeIntervalSince(idleSince!) > 3 { t.idle = true; break }
            }
            if status == .shell { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let added = Self.mirrorLines(mirrorURL(s)).dropFirst(mirrorStart)
        t.reply = added.filter { $0.type == "assistant" }.map(\.text).joined(separator: "\n")
        t.users = added.filter { $0.type == "user" && !$0.text.isEmpty }.map(\.text)
        t.tools = added.flatMap(\.tools)
        t.log = Array(Self.lines(logURL(s)).dropFirst(logStart))
        print("E2E: turn \"\(prompt.prefix(60))\" busy=\(t.sawBusy) idle=\(t.idle) prompts=\(t.prompts) "
            + "tools=\(t.tools.map(\.name)) reply=\(t.reply.suffix(200).debugDescription)")
        return t
    }

    /// `sh` off the main actor — for a command whose answer needs the main actor (the bridge
    /// listener routes there), so blocking on it in place would deadlock until the timeout.
    nonisolated private static func shDetached(_ argv: [String], timeout: TimeInterval = 60) async
        -> (code: Int32, stdout: String)? {
        await Task.detached { sh(argv, timeout: timeout) }.value
    }

    @discardableResult
    nonisolated private static func sh(_ argv: [String], timeout: TimeInterval = 60) -> (code: Int32, stdout: String)? {
        LocalCommandRunner().run(argv, cwd: nil, timeout: timeout)
    }

    /// The local `docker exec` client processes of this test run's agents (children of this
    /// process whose arguments name the ACP package), newest last.
    /// (`pgrep`, not `ps -ax`: a full process list can outgrow the runner's pipe.)
    private static func agentClientPIDs() -> [Int32] {
        guard let out = sh(["/usr/bin/pgrep", "-P", "\(getpid())", "-f", "claude-agent-acp"], timeout: 10)?.stdout
        else { return [] }
        return out.split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }.sorted()
    }

    // MARK: - Test connection

    /// Settings → Agents' Test connection: `initialize` only, plus the exec probes.
    func testConnectionReportsAgentAndCapabilities() async throws {
        wire(manager, agent: agent(), bridgeRunning: true)
        let result = await manager.testACPConnection(agent())
        guard case let .connected(r) = result else {
            return record("Test connection", false, "\(result)")
        }
        let n = r.negotiated
        let detail = "agent=\(n.agentName ?? "nil") \(n.agentVersion ?? "nil") fork=\(n.fork) list=\(n.list) "
            + "resume=\(n.resume) steering=\(n.steering) mcpHTTP=\(n.mcpHTTP) loadSession=\(n.loadSession) "
            + "git=\(String(describing: r.git)) gh=\(String(describing: r.gh)) "
            + "ghAuthed=\(String(describing: r.ghAuthed))"
        let ok = n.agentName?.hasSuffix("claude-agent-acp") == true && n.agentVersion == "0.100.0"
            && n.fork && n.list && n.resume && n.steering && n.mcpHTTP
            && r.git == true && r.gh == true && r.ghAuthed == true
        record("Test connection", ok, detail)
    }

    // MARK: - Import

    /// Import sessions… lists the agent's sessions in its cwd — including ones started with
    /// plain `claude` in the container (their transcripts are under `projects/-workspace`).
    func testImportListsPlainClaudeSessions() async throws {
        let a = agent()
        wire(manager, agent: a, bridgeRunning: false)
        let found = await manager.importACPSessions(agent: a)
        let onDisk = Self.sh([
            "docker", "exec", Self.container, "sh", "-c",
            "ls /home/node/.claude/projects/-workspace/ | sed -n 's/\\.jsonl$//p'",
        ])?.stdout.split(separator: "\n").map(String.init) ?? []
        let plain = found.filter { onDisk.contains($0.acpSessionID) }
        let sample = plain.prefix(3).map { "\($0.acpSessionID.prefix(8))… \($0.title?.prefix(40) ?? "nil")" }
        record("Import sessions lists plain-claude sessions",
               !found.isEmpty && !plain.isEmpty,
               "listed=\(found.count) matching /workspace transcripts=\(plain.count) e.g. \(sample)")
    }

    // MARK: - One tab, start to finish

    /// One ACP tab through every checklist line that needs a live session, in order: prompt
    /// and status, permissions mode, the bridge (401 + set_goal_self) and goal hooks, the
    /// footprint, steering via a hail, fork, a relaunch restore, and an agent that dies
    /// mid-turn followed by Retry.
    func testTabLifecycleAgainstRealAgent() async throws {
        // A throwaway repo in the container: the tab works there, never under /workspace.
        let dir = "/tmp/admiral-e2e-\(UUID().uuidString.prefix(8).lowercased())"
        repoDir = dir
        let made = Self.sh(["docker", "exec", Self.container, "sh", "-c",
                            "mkdir -p \(dir) && git -C \(dir) init -q -b e2e-branch && git -C \(dir) -c user.name=e2e "
                            + "-c user.email=e2e@example.invalid commit -q --allow-empty -m init && echo ok"])
        XCTAssertEqual(made?.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "ok", "repo setup failed")

        guard let port = startBridge(for: manager) else { return XCTFail("could not bind a bridge listener") }
        print("E2E: session bridge listener on 127.0.0.1:\(port)")
        let a = agent(cwd: dir, callbackPort: port)
        wire(manager, agent: a, bridgeRunning: true)

        // Unauthenticated POST from the container → 401.
        let curl = await Self.shDetached(["docker", "exec", Self.container, "curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
                            "-X", "POST", "http://host.docker.internal:\(port)/mcp/session"])
        record("Bridge 401 from container", curl?.stdout == "401",
               "curl -X POST http://host.docker.internal:\(port)/mcp/session -> \(curl?.stdout ?? "nil")")

        // A PTY tab to hail from, selected — so the ACP tab is the one "not looked at".
        let pty = manager.commission(callsign: "e2e-pty", cwd: NSTemporaryDirectory())
        let tab = manager.commissionACP(agent: a, callsign: "e2e-acp")
        manager.selectedID = pty.id
        let opened = await until("handshake", timeout: 240) { session(tab.id)?.status == .idle }
        guard opened, let ready = session(tab.id) else {
            let log = Self.lines(logURL(tab)).suffix(15).joined(separator: "\n")
            return record("Open tab", false, "no idle after 240 s; status=\(String(describing: session(tab.id)?.status)) "
                + "error=\(session(tab.id)?.connectError ?? "nil")\n\(log)")
        }
        let caps = ready.acpCapabilities
        let setMode = Self.lines(logURL(ready)).filter { $0.contains("session/set_config_option") }
        record("Open tab", ready.acpSessionID != nil,
               "acpSessionID=\(ready.acpSessionID ?? "nil") bridgeTools=\(caps?.isEnabled(.bridgeTools) == true) "
               + "steering=\(caps?.isEnabled(.steering) == true)")

        // 1. Prompt → streamed reply; busy → idle; unseen work on the tab not looked at.
        let t1 = await turn(tab.id, "Reply with exactly: pong")
        let goalsReminderSent = t1.log.contains { $0.hasPrefix("acp: -> ") && $0.contains("ADMIRAL GOALS") }
        record("Prompt → streamed reply, busy → idle, unseen dot",
               t1.sawBusy && t1.idle && t1.reply.lowercased().contains("pong") && t1.messageChunks >= 1
                   && session(tab.id)?.hasUnseenWork == true,
               "busy=\(t1.sawBusy) idle=\(t1.idle) chunks=\(t1.messageChunks) reply=\(t1.reply.debugDescription) "
               + "hasUnseenWork=\(session(tab.id)?.hasUnseenWork == true)")

        // 2. Goals over the bridge, a Bash call with no permission card, and file edits in the repo.
        let sid = ready.claudeSessionID!
        let t2 = await turn(tab.id, "Do these steps in order. 1) Call the set_goal_self tool (admiral MCP server) "
            + "with exactly one goal: text \"notes.txt contains hello world\", check \"cat notes.txt\". "
            + "2) Run `echo bash-ok` with the Bash tool. 3) Create notes.txt in the current directory "
            + "containing hello, using the Write tool. 4) Change it to hello world using the Edit tool. "
            + "Do not call update_goals until you are asked to review your goals. Then reply with exactly: done")
        let modeOK = setMode.contains { $0.contains("bypassPermissions") }
            && !Self.lines(logURL(ready)).contains { $0.contains("refused mode") }
        let ranBash = t2.tools.contains { $0.name == "Bash" }
        // Whether the Chat's Bash card can show its command: the mirror's tool_use input.
        let bashInput = t2.tools.first { $0.name == "Bash" }?.input ?? "nil"
        record("Mode bypassPermissions (Bash runs, no permission card)",
               modeOK && ranBash && bashInput.contains("bash-ok")
                   && t2.permissionRequests == 0 && t1.permissionRequests == 0,
               "set_config_option lines=\(setMode.count) bash=\(ranBash) bash input in mirror=\(bashInput) permissionRequests=\(t2.permissionRequests) "
               + "tools=\(t2.tools.map(\.name))")
        let goals = GoalsStore(base: base).goals(forSession: sid)
        let goalTool = t2.tools.contains { $0.name.contains("set_goal_self") }
        let hits = listener?.hits ?? []
        record("set_goal_self via the bridge; reminder + end-of-turn review",
               goalTool && (goals?.visible.count ?? 0) >= 1 && goalsReminderSent && t2.prompts >= 2,
               "tool used=\(goalTool) goals=\(goals?.visible.map { "\($0.id):\($0.text) [\($0.status)]" } ?? []) "
               + "reminder in prompt=\(goalsReminderSent) session/prompt this turn=\(t2.prompts) "
               + "bridge hits=\(hits.count) statuses=\(Set(hits.map(\.status)).sorted())")

        // Footprint: the repo and its branch, through the agent's exec.
        manager.refreshTouchedRepos(for: tab.id)
        await until("footprint", timeout: 30) { session(tab.id)?.touchedRepos.contains { $0.root == dir } == true }
        manager.refreshGitBranch(for: tab.id)
        await until("branch", timeout: 30) {
            session(tab.id)?.touchedRepos.first { $0.root == dir }?.branches.contains("e2e-branch") == true
                && session(tab.id)?.gitBranch == "e2e-branch"
        }
        let repo = session(tab.id)?.touchedRepos.first { $0.root == dir }
        let caps2 = session(tab.id)?.acpCapabilities
        record("Edit a file → Footprint repo + branch (PR watch: no PR exists)",
               repo != nil && repo?.branches.contains("e2e-branch") == true
                   && session(tab.id)?.gitBranch == "e2e-branch",
               "repos=\(session(tab.id)?.touchedRepos.map { "\($0.root) \($0.branches) files=\($0.filesWritten)" } ?? []) "
               + "gitBranch=\(session(tab.id)?.gitBranch ?? "nil") "
               + "prWatch reason=\(caps2?.reason(.prWatch) ?? "on")")

        // 3. Steering: hail from the PTY tab while the ACP tab is mid-turn.
        var hailResult: BridgeResult?
        let t3 = await turn(tab.id, "Run `sleep 20` with the Bash tool, then reply with exactly: slept") { lines in
            guard lines.contains(where: { $0.tools.contains { $0.name == "Bash" && $0.input.contains("sleep") } })
            else { return false }
            hailResult = self.bridge.hail(fromToken: pty.token, to: "e2e-acp",
                                          body: "Also end your reply with the word banana.")
            return true
        }
        // Taken mid-turn = a `_session/steering` the agent answered without `promptRequired`, the
        // hail mirrored inside that turn. (Further session/prompts this turn are the goal review.)
        let steerSent = t3.log.firstIndex { $0.hasPrefix("acp: -> ") && $0.contains("_session/steering") }
        let steerAnswer = steerSent.flatMap { i in
            t3.log[(i + 1)...].first { $0.hasPrefix("acp: <- ") && $0.contains("\"result\"") && $0.contains("outcome") }
        }
        let injected = steerAnswer.map { $0.contains("injected") && !$0.contains("promptRequired") } ?? false
        record("Hail mid-turn arrives as a steer",
               hailResult?.ok == true && injected && t3.users.contains { $0.contains("banana") },
               "hail=\(hailResult?.message ?? "not sent") steer answer=\(steerAnswer?.suffix(60) ?? "none") "
               + "mirrored in turn=\(t3.users.contains { $0.contains("banana") }) session/prompt this turn=\(t3.prompts) "
               + "reply=\(t3.reply.suffix(120).debugDescription)")

        // 4. Fork → a new ACP tab with the history (the copy in Chat, the agent's in its memory).
        let before = Set(manager.sessions.map(\.id))
        manager.fork(tab.id)
        await until("fork tab", timeout: 10) { manager.sessions.count > before.count }
        let forkID = manager.sessions.first { !before.contains($0.id) }?.id
        var forkOK = false
        var forkDetail = "no fork tab"
        if let forkID {
            await until("fork idle", timeout: 240) { session(forkID)?.status == .idle }
            let f = session(forkID)!
            let copied = Self.mirrorLines(mirrorURL(f)).contains { $0.text.lowercased().contains("pong") }
            let t4 = await turn(forkID, "What word did I ask you to end a reply with? Reply with just that word.")
            forkOK = f.acpSessionID != nil && f.acpSessionID != ready.acpSessionID && copied
                && t4.reply.lowercased().contains("banana")
            forkDetail = "fork acpSessionID=\(f.acpSessionID ?? "nil") (source \(ready.acpSessionID ?? "nil")) "
                + "mirror has history=\(copied) reply=\(t4.reply.debugDescription) "
                + "error=\(f.connectError ?? "nil")"
        }
        record("Fork → new ACP tab with history", forkOK, forkDetail)

        // 5. Quit and relaunch: a new manager over the same support dir and defaults restores the tab.
        let mirrorCount = Self.mirrorLines(mirrorURL(ready)).count
        manager.terminateAll()
        listener?.stop()
        let m2 = makeManager()
        manager = m2
        guard let port2 = startBridge(for: m2) else { return XCTFail("could not rebind the bridge listener") }
        let a2 = agent(cwd: dir, callbackPort: port2)
        wire(m2, agent: a2, bridgeRunning: true)
        let records = OpenSessionsStore(defaults: defaults).all()
        var restoredID: UUID?
        for r in records {
            if case let .acp(agentConfig, acpSessionID) = m2.restorePlan(for: r) {
                let s = m2.restoreACP(r, agent: agentConfig, acpSessionID: acpSessionID)
                if r.sessionID == sid { restoredID = s.id }
            }
        }
        guard let restoredID else {
            return record("Quit + relaunch restores the tab", false,
                          "no ACP restore plan for \(sid); records=\(records.map(\.sessionID))")
        }
        await until("restore idle", timeout: 240) { session(restoredID)?.status == .idle }
        let restored = session(restoredID)!
        let history = Self.mirrorLines(mirrorURL(restored)).count
        let t5 = await turn(restoredID, "What word did I ask you to end a reply with? Reply with just that word.")
        let restoreMethod = Self.lines(logURL(restored)).last {
            $0.hasPrefix("acp: -> ") && ($0.contains("session/resume") || $0.contains("session/load"))
        }.map { $0.contains("session/resume") ? "session/resume" : "session/load" } ?? "none"
        record("Quit + relaunch restores the tab with history",
               restored.status == .idle && restored.acpSessionID == ready.acpSessionID
                   && history >= mirrorCount && t5.reply.lowercased().contains("banana"),
               "restored \(records.count) record(s); via \(restoreMethod); acpSessionID same="
               + "\(restored.acpSessionID == ready.acpSessionID) mirror lines \(mirrorCount)→\(history) "
               + "reply=\(t5.reply.debugDescription)")

        // 6. The agent dies mid-turn (SUBSTITUTED for `docker stop`: the local docker exec client
        // is SIGKILLed), then Retry (reload) reconnects.
        var killed: Int32?
        var busyAtKill = false
        let t6 = await turn(restoredID, "Run `sleep 20` with the Bash tool, then reply with exactly: ok",
                            in: m2, timeout: 60) { lines in
            guard lines.contains(where: { $0.tools.contains { $0.name == "Bash" && $0.input.contains("sleep") } }),
                  let pid = self.agentPIDByLog[self.logURL(restored).path] else { return false }
            busyAtKill = self.session(restoredID, in: m2)?.status == .busy
            kill(pid, SIGKILL)
            killed = pid
            return true
        }
        let deadStart = Date()
        await until("dead tab", timeout: 20) { session(restoredID, in: m2)?.status == .shell }
        let dead = session(restoredID, in: m2)
        let reason = dead?.connectError ?? "nil"
        record("Agent dies mid-turn → shell with a reason, nothing hangs",
               // The reason is the agent's words or Admiral's — never a fragment of traced JSON.
               killed != nil && busyAtKill && dead?.status == .shell && dead?.connectError != nil
                   && !reason.contains("\""),
               "SIGKILL pid=\(killed.map(String.init) ?? "none") status=\(String(describing: dead?.status)) "
               + "after \(String(format: "%.1f", Date().timeIntervalSince(deadStart))) s reason=\(reason.debugDescription) "
               + "busy at kill=\(busyAtKill)")

        let retried = m2.reload(restoredID)
        var retryOK = false
        var retryDetail = "reload returned nil"
        if let retried {
            await until("retry idle", timeout: 240) { session(retried.id, in: m2)?.status == .idle }
            let r = session(retried.id, in: m2)
            retryOK = r?.status == .idle && r?.acpSessionID == ready.acpSessionID && r?.connectError == nil
            retryDetail = "status=\(String(describing: r?.status)) acpSessionID same=\(r?.acpSessionID == ready.acpSessionID) "
                + "error=\(r?.connectError ?? "nil")"
        }
        record("Retry reconnects", retryOK, retryDetail)
    }
}

/// A minimal HTTP listener on 127.0.0.1 for the session bridge route: one request per
/// connection (`HTTPWire`), routed on the main actor — the App's `LoopbackHTTPListener`
/// in miniature, since that type is not in Core. Records each answer's status.
final class LoopbackTestListener: @unchecked Sendable {
    private let route: @MainActor (HTTPRequest) async -> Data
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var stopped = false
    private var _hits: [(path: String, status: Int)] = []
    var hits: [(path: String, status: Int)] { lock.withLock { _hits } }

    init(route: @escaping @MainActor (HTTPRequest) async -> Data) { self.route = route }

    func start(preferredPort: UInt16) -> UInt16? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = preferredPort.bigEndian
        addr.sin_addr = in_addr(s_addr: UInt32(INADDR_LOOPBACK).bigEndian)
        let len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) == 0 }
        }
        guard bound, listen(fd, 16) == 0 else { close(fd); return nil }
        var got = sockaddr_in()
        var gotLen = len
        _ = withUnsafeMutablePointer(to: &got) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &gotLen) }
        }
        lock.withLock { self.fd = fd; stopped = false }
        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.start()
        return UInt16(bigEndian: got.sin_port)
    }

    func stop() {
        lock.withLock {
            stopped = true
            if fd >= 0 { close(fd); fd = -1 }
        }
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&p, 1, 200)
            if lock.withLock({ stopped }) { return }
            guard ready > 0 else { continue }
            let conn = accept(fd, nil, nil)
            guard conn >= 0 else { continue }
            var noSigPipe: Int32 = 1
            setsockopt(conn, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            DispatchQueue.global().async { self.handle(conn) }
        }
    }

    private func handle(_ conn: Int32) {
        guard let request = HTTPWire.readRequest(from: conn) else { close(conn); return }
        let route = self.route
        Task { @MainActor in
            let data = await route(request)
            let head = String(decoding: data.prefix(32), as: UTF8.self).split(separator: " ")
            let status = head.count > 1 ? Int(head[1]) ?? 0 : 0
            self.lock.withLock { self._hits.append((request.path, status)) }
            data.withUnsafeBytes { buf in
                var ptr = buf.baseAddress
                var left = buf.count
                while left > 0, let p = ptr {
                    let n = write(conn, p, left)
                    if n <= 0 { break }
                    ptr = p.advanced(by: n)
                    left -= n
                }
            }
            close(conn)
        }
    }
}
