import Combine
import XCTest
@testable import AdmiralCore

/// ACP tabs inside `SessionManager`: commission, persistence, status, input, restore, fork,
/// delete and import — each against a scripted agent handed out by the transport factory.
@MainActor
final class SessionManagerAcpTests: XCTestCase {
    private var base: URL!
    private var defaults: UserDefaults!
    private var manager: SessionManager!
    /// Agents handed out by the transport factory, in launch order. Each launch takes the
    /// next from `scripted`, or a default agent when the list runs out.
    private var scripted: [ScriptedAgent] = []
    private var launched: [ScriptedAgent] = []
    private var launchedConfigs: [AcpAgentConfig] = []
    private var launchedLogs: [URL] = []
    /// Folder the agent works in — absent on this Mac, like a container path.
    private let agentCwd = "/nonexistent-\(UUID().uuidString)/workspace"
    private var ppt: AcpAgentConfig!
    /// What the tab's exec runner is (`acpRunnerFactory`); nil = the agent has no exec.
    /// A fake, so no test ever spawns `docker exec`.
    private var execRunner: ExecFake?

    /// Answers like an environment with git (on `feature-x`) and gh, logged in or not.
    private final class ExecFake: CommandRunner, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [[String]] = []
        var calls: [[String]] { lock.withLock { _calls } }
        let ghAuthed: Bool
        let defaultTimeout: TimeInterval = 5

        init(ghAuthed: Bool = true) { self.ghAuthed = ghAuthed }

        func run(_ argv: [String], cwd: String?, timeout: TimeInterval) -> (code: Int32, stdout: String)? {
            lock.withLock { _calls.append(argv) }
            if argv == ["gh", "auth", "status"] { return (ghAuthed ? 0 : 1, "") }
            if argv.contains("--version") { return (0, "") }
            if argv.contains("symbolic-ref") { return (0, "feature-x\n") }
            return (1, "")
        }
    }

    private let fork: JSONValue = .object(["sessionCapabilities": .object(["fork": .object([:])])])
    private let close: JSONValue = .object(["sessionCapabilities": .object(["close": .object([:])])])
    private let resume: JSONValue = .object(["sessionCapabilities": .object(["resume": .object([:])])])
    private let list: JSONValue = .object(["sessionCapabilities": .object(["list": .object([:])])])

    override func setUp() async throws {
        try await super.setUp()
        base = FileManager.default.temporaryDirectory.appendingPathComponent("acp-mgr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let suite = "acp-mgr-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        manager = SessionManager(
            host: FakeTerminalHost(), claudeHome: base, executablePath: "/bin/echo",
            appearanceStore: SessionAppearanceStore(defaults: defaults),
            openSessionsStore: OpenSessionsStore(defaults: defaults), supportDir: base,
            touchedReposStore: TouchedReposStore(defaults: defaults))
        ppt = AcpAgentConfig(name: "PPT", launch: AcpCommand(command: "docker", args: ["exec", "-i", "c", "agent"]),
                             cwd: agentCwd, workspace: .elsewhere(exec: AcpCommand(command: "docker", args: ["exec", "c"])),
                             mcpCallbackURL: "http://host.docker.internal:4142")
        scripted = []
        launched = []
        launchedConfigs = []
        launchedLogs = []
        manager.acpAgents = { [unowned self] in [ppt] }
        execRunner = ExecFake()
        manager.acpRunnerFactory = { [unowned self] _ in execRunner }
        manager.acpTransportFactory = { [unowned self] config, log in
            let agent = scripted.isEmpty ? ScriptedAgent() : scripted.removeFirst()
            launched.append(agent)
            launchedConfigs.append(config)
            launchedLogs.append(log)
            return agent
        }
    }

    override func tearDown() {
        manager.terminateAll()
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: - Helpers

    private func until(
        _ what: String = "condition", timeout: TimeInterval = 3,
        file: StaticString = #filePath, line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for \(what)", file: file, line: line) }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    private func session(_ id: UUID) -> AgentSession? { manager.sessions.first { $0.id == id } }

    /// A commissioned ACP tab whose handshake finished (status `.idle`).
    private func readyTab(
        _ agent: ScriptedAgent = ScriptedAgent(), callsign: String = "fix-bug"
    ) async -> AgentSession {
        scripted.append(agent)
        let s = manager.commissionACP(agent: ppt, callsign: callsign)
        await until("handshake") { session(s.id)?.status == .idle }
        return session(s.id) ?? s
    }

    /// An agent whose `session/new` advertises claude-agent-acp's `mode` and `model` options.
    private func advertisingAgent() -> ScriptedAgent {
        let agent = ScriptedAgent()
        let result = (try? JSONDecoder().decode(
            JSONValue.self, from: Data(AcpConfigOptionsTests.claudeAgentACP.utf8))) ?? .null
        agent.on("session/new") { _ in .result(result) }
        return agent
    }

    private func lines(_ url: URL) -> [String] {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    // MARK: - Live command output

    /// A command's output on `_meta.terminal_output`, as claude-agent-acp streams it.
    private func output(_ agent: ScriptedAgent, _ data: String, call: String = "t1", status: String? = nil) {
        var update: [String: JSONValue] = [
            "sessionUpdate": .string("tool_call_update"), "toolCallId": .string(call),
            "_meta": .object(["terminal_output": .object(["terminal_id": .string(call), "data": .string(data)])]),
        ]
        if let status { update["status"] = .string(status) }
        agent.notify(update: .object(update))
    }

    private func closeCall(_ agent: ScriptedAgent, _ call: String = "t1", status: String = "completed") {
        agent.notify(update: .object([
            "sessionUpdate": .string("tool_call_update"), "toolCallId": .string(call), "status": .string(status),
        ]))
    }

    func testLiveOutputIsCoalescedThenDroppedWhenTheCallCompletes() async {
        var flushes: [@MainActor () -> Void] = []
        manager.acpLiveFlushScheduler = { flushes.append($0) }
        let agent = ScriptedAgent()
        let s = await readyTab(agent)
        var publishes = 0
        let watch = manager.$sessions.dropFirst().sink { _ in publishes += 1 }
        defer { watch.cancel() }
        for chunk in ["a", "b", "c", "d"] { output(agent, chunk) }
        await until("every chunk buffered") { manager.acpLivePending[s.id]?["t1"] == "abcd" }
        XCTAssertEqual(publishes, 0, "chunks never publish the session on their own")
        XCTAssertEqual(flushes.count, 1, "one flush for a burst")
        XCTAssertEqual(session(s.id)?.acpLiveOutput, [:], "nothing published before the flush")
        let before = session(s.id)?.lastActivityAt
        flushes.removeFirst()()
        XCTAssertEqual(publishes, 1, "the burst is one publish")
        XCTAssertEqual(session(s.id)?.acpLiveOutput, ["t1": "abcd"])
        XCTAssertNotEqual(session(s.id)?.lastActivityAt, before, "the flush stamps the activity")
        output(agent, "e")
        await until("next burst scheduled") { flushes.count == 1 }
        flushes.removeFirst()()
        XCTAssertEqual(session(s.id)?.acpLiveOutput, ["t1": "abcde"])
        closeCall(agent)
        await until("completed call dropped") { session(s.id)?.acpLiveOutput.isEmpty == true }
        // A straggling chunk on its own notification after the close opens nothing again.
        output(agent, "late")
        output(agent, "other", call: "t2")
        await until("the next call's chunk buffered") { manager.acpLivePending[s.id]?["t2"] == "other" }
        XCTAssertNil(manager.acpLivePending[s.id]?["t1"])
    }

    func testLiveOutputKeepsTheLast8KBAndFailedCallsDropIt() async {
        var flushes: [@MainActor () -> Void] = []
        manager.acpLiveFlushScheduler = { flushes.append($0) }
        let agent = ScriptedAgent()
        let s = await readyTab(agent)
        output(agent, String(repeating: "x", count: 9000) + "END")
        await until("flush scheduled") { flushes.count == 1 }
        flushes.removeFirst()()
        let kept = session(s.id)?.acpLiveOutput["t1"] ?? ""
        XCTAssertEqual(kept.utf8.count, 8 * 1024)
        XCTAssertTrue(kept.hasSuffix("END"))
        closeCall(agent, status: "failed")
        await until("failed call dropped") { session(s.id)?.acpLiveOutput.isEmpty == true }
    }

    func testLiveOutputGoesWhenTheTurnEnds() async {
        var flushes: [@MainActor () -> Void] = []
        manager.acpLiveFlushScheduler = { flushes.append($0) }
        let agent = ScriptedAgent()
        let s = await readyTab(agent)
        XCTAssertTrue(manager.send(s.id, text: "go"))
        await until("prompt sent") { agent.heldPrompts == 1 }
        output(agent, "running")
        await until("flush scheduled") { flushes.count == 1 }
        flushes.removeFirst()()
        XCTAssertEqual(session(s.id)?.acpLiveOutput, ["t1": "running"])
        agent.endPrompt()
        await until("turn over") { session(s.id)?.status == .idle }
        XCTAssertEqual(session(s.id)?.acpLiveOutput, [:])
    }

    // MARK: - Commission

    func testCommissionACPCreatesTabWithMirrorTranscriptAndACPBackend() async {
        scripted.append(ScriptedAgent())
        let s = manager.commissionACP(agent: ppt, callsign: "fix-bug")
        let sid = try! XCTUnwrap(s.claudeSessionID)
        XCTAssertEqual(sid, sid.lowercased())
        XCTAssertNotNil(UUID(uuidString: sid))
        XCTAssertEqual(s.backend, .acp(agentName: "PPT"))
        XCTAssertEqual(s.transcriptPath, TranscriptMirror.url(base: base, session: sid).path)
        XCTAssertEqual(s.cwd, agentCwd)
        XCTAssertEqual(s.status, .unknown)
        XCTAssertEqual(s.displayTitle, "fix-bug")
        XCTAssertEqual(manager.sessions.map(\.id), [s.id])
        XCTAssertEqual(manager.selectedID, s.id)
        XCTAssertEqual(launchedLogs, [SessionManager.acpLogURL(base: base, session: sid)])
        XCTAssertEqual(SessionManager.acpLogURL(base: base, session: sid),
                       base.appendingPathComponent("acp").appendingPathComponent("\(sid).log"))
        await until("handshake") { session(s.id)?.status == .idle }
        XCTAssertEqual(launched.first?.methods.prefix(2), ["initialize", "session/new"])
        XCTAssertEqual(launched.first?.params(of: "session/new").first?["cwd"]?.stringValue, agentCwd)
    }

    /// The session bridge rides on `session/new` only while Admiral's listener runs: then it is
    /// `<mcpCallbackURL>/mcp/session` with the tab's own token as the bearer; otherwise there is
    /// no MCP server, and the tab says why.
    func testSessionBridgeIsOfferedOnlyWhileTheListenerRuns() async throws {
        let http: JSONValue = .object(["mcpCapabilities": .object(["http": .bool(true)])])
        let down = await readyTab(ScriptedAgent(capabilities: http), callsign: "down")
        XCTAssertEqual(launched.last?.params(of: "session/new").first?["mcpServers"]?.arrayValue?.count, 0)
        await until("record") { session(down.id)?.acpCapabilities != nil }
        XCTAssertEqual(session(down.id)?.acpCapabilities?.reason(.bridgeTools),
                       "Admiral's session bridge is not running")

        manager.sessionBridgeRunning = { true }
        let up = await readyTab(ScriptedAgent(capabilities: http), callsign: "up")
        let server = try XCTUnwrap(launched.last?.params(of: "session/new").first?["mcpServers"]?.arrayValue?.first)
        XCTAssertEqual(server["name"]?.stringValue, "admiral")
        XCTAssertEqual(server["url"]?.stringValue, "http://host.docker.internal:4142/mcp/session")
        XCTAssertEqual(server["headers"]?.arrayValue?.first?["value"]?.stringValue, "Bearer \(up.token)")
        await until("record") { session(up.id)?.acpCapabilities != nil }
        XCTAssertNil(session(up.id)?.acpCapabilities?.reason(.bridgeTools))
    }

    func testCommissionACPUsesTheGivenCwdOverTheAgentsDefault() async {
        scripted.append(ScriptedAgent())
        let s = manager.commissionACP(agent: ppt, callsign: "x", cwd: "/workspace/other")
        XCTAssertEqual(s.cwd, "/workspace/other")
        await until("handshake") { session(s.id)?.status == .idle }
        XCTAssertEqual(launched.first?.params(of: "session/new").first?["cwd"]?.stringValue, "/workspace/other")
        XCTAssertEqual(launchedConfigs.first?.cwd, "/workspace/other")
    }

    func testAgentSessionIDPersistedAfterSessionNew() async {
        scripted.append(ScriptedAgent())
        let s = manager.commissionACP(agent: ppt, callsign: "fix-bug")
        XCTAssertTrue(manager.restorableSessions().isEmpty, "nothing to restore before the agent named its session")
        await until("record") { !manager.restorableSessions().isEmpty }
        let record = manager.restorableSessions().first
        XCTAssertEqual(record?.acpAgentName, "PPT")
        XCTAssertEqual(record?.acpSessionID, "s1")
        XCTAssertEqual(record?.sessionID, s.claudeSessionID, "Admiral state stays keyed by the local id")
        XCTAssertEqual(record?.cwd, agentCwd)
        XCTAssertEqual(session(s.id)?.acpSessionID, "s1")
    }

    func testScratchACPTabIsNotPersisted() async {
        scripted.append(ScriptedAgent())
        let s = manager.commissionACP(agent: ppt, callsign: "tmp", scratch: true)
        await until("handshake") { session(s.id)?.status == .idle }
        XCTAssertTrue(manager.restorableSessions().isEmpty)
        XCTAssertNil(manager.selectedID)
    }

    func testOldRecordsDecodeWithoutACPFields() throws {
        let json = #"[{"cwd":"/tmp","sessionID":"a","callsign":"c"}]"#
        let records = try JSONDecoder().decode([OpenSessionRecord].self, from: Data(json.utf8))
        XCTAssertNil(records.first?.acpAgentName)
        XCTAssertNil(records.first?.acpSessionID)
    }

    func testSetTeamKeepsTheACPRecord() async {
        let s = await readyTab()
        await until("record") { manager.restorableSessions().first?.acpSessionID == "s1" }
        manager.setTeam(s.id, team: "blue")
        let record = manager.restorableSessions().first
        XCTAssertEqual(record?.teamName, "blue")
        XCTAssertEqual(record?.acpAgentName, "PPT")
        XCTAssertEqual(record?.acpSessionID, "s1")
    }

    // MARK: - Status / input

    func testStatusComesFromControllerNotSessionFiles() async throws {
        let agent = ScriptedAgent()
        let s = await readyTab(agent)
        let sid = try XCTUnwrap(s.claudeSessionID)
        // A claude session file claiming the same id is idle: it must not win over the controller.
        let dir = base.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"pid":999,"sessionId":"\#(sid)","status":"idle","updatedAt":1}"#.utf8)
            .write(to: dir.appendingPathComponent("999.json"))
        XCTAssertTrue(manager.inject(s.id, text: "work"))
        await until("busy") { session(s.id)?.status == .busy }
        manager.refreshStatuses()
        XCTAssertEqual(session(s.id)?.status, .busy)
        manager.resolveTranscript(for: s.id)
        XCTAssertEqual(session(s.id)?.transcriptPath, TranscriptMirror.url(base: base, session: sid).path)
        await until("prompt") { agent.heldPrompts == 1 }
        agent.endPrompt()
        await until("idle") { session(s.id)?.status == .idle }
    }

    func testInjectRoutesToSessionPrompt() async throws {
        let agent = ScriptedAgent()
        let s = await readyTab(agent)
        let sid = try XCTUnwrap(s.claudeSessionID)
        XCTAssertTrue(manager.inject(s.id, text: "hello there"))
        await until("prompt") { !agent.prompts().isEmpty }
        XCTAssertEqual(agent.prompts().count, 1)
        XCTAssertTrue(agent.prompts()[0].hasSuffix("hello there"), agent.prompts()[0])
        // The mark went down before the in-process UserPromptSubmit ran, so the chat shows it as Admiral's.
        await until("ledger") {
            ChatLedger.read(base: base, session: sid).contains { $0.kind == .prompt && $0.text == "hello there" }
        }
        let event = ChatLedger.read(base: base, session: sid).first { $0.kind == .prompt }
        XCTAssertEqual(event?.source, "admiral")
    }

    func testSendAndAnswerReportTheDriversResult() async {
        let s = await readyTab()
        XCTAssertTrue(manager.send(s.id, text: "typed"))
        XCTAssertFalse(manager.answerAsk(s.id, questions: [], answers: []), "no open question")
        XCTAssertFalse(manager.allowPermission(s.id), "no open permission")
        XCTAssertFalse(manager.send(UUID(), text: "nowhere"))
    }

    func testFailedHandshakeStrandsNothingSilently() async throws {
        let agent = advertisingAgent()
        ppt.defaultConfigOptions = ["mode": "bypassPermissions"]
        agent.on("session/set_config_option") { _ in .error(-32603, "root needs IS_SANDBOX=1") }
        scripted.append(agent)
        let s = manager.commissionACP(agent: ppt, callsign: "x")
        let sid = try XCTUnwrap(s.claudeSessionID)
        // Typed while the handshake is still running: queued, then stranded by the failure.
        XCTAssertTrue(manager.inject(s.id, text: "queued while connecting"))
        await until("dead tab") { session(s.id)?.status == .shell }
        await until("terminated") { agent.fake.terminated }
        let log = lines(SessionManager.acpLogURL(base: base, session: sid)).joined(separator: "\n")
        XCTAssertTrue(log.contains("root needs IS_SANDBOX=1"), log)
        XCTAssertTrue(log.contains("queued while connecting"), log)
        // A refused text leaves no marker behind for a later identical prompt to be mistaken by.
        XCTAssertFalse(manager.inject(s.id, text: "after death"))
        let markers = (try? String(contentsOf: ChatLedger.injectedURL(base: base, session: sid), encoding: .utf8)) ?? ""
        XCTAssertFalse(markers.contains("after death"), markers)
    }

    func testConnectionLogGoesToTheACPLog() async throws {
        let agent = ScriptedAgent()
        let s = await readyTab(agent)
        agent.fake.feed("this is not json")
        let url = SessionManager.acpLogURL(base: base, session: try XCTUnwrap(s.claudeSessionID))
        await until("log line") { lines(url).contains { $0.contains("this is not json") } }
    }

    func testInjectToIdleCompletesATabRun() async throws {
        let agent = ScriptedAgent()
        let s = await readyTab(agent)
        let path = try XCTUnwrap(s.transcriptPath)
        let run = TabRun(backend: manager, config: TabRun.Config(busySeenTimeout: 30, turnTimeout: 5,
                                                                 pollInterval: 0.01))
        XCTAssertTrue(manager.inject(s.id, text: "go"))
        await until("prompt") { agent.heldPrompts == 1 }
        Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            agent.say("all done")
            agent.endPrompt()
        }
        let turn = await run.awaitTurn(tabID: s.id, path: path, fromOffset: 0)
        XCTAssertFalse(turn.timedOut)
        XCTAssertTrue(turn.text.contains("all done"), turn.text)

        // A prompt that ends in a request error emits no turnEnded: idle alone ends the run.
        let offset = (try? Data(contentsOf: URL(fileURLWithPath: path)).count) ?? 0
        XCTAssertTrue(manager.inject(s.id, text: "again"))
        await until("second prompt") { agent.heldPrompts == 1 }
        Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            agent.failPrompt(message: "overloaded")
        }
        let failed = await run.awaitTurn(tabID: s.id, path: path, fromOffset: offset)
        XCTAssertFalse(failed.timedOut)
        XCTAssertEqual(session(s.id)?.status, .idle)
    }

    func testTransportEndingMidPromptEndsTheTabRunAsAFailure() async throws {
        let agent = ScriptedAgent()
        let s = await readyTab(agent)
        let path = try XCTUnwrap(s.transcriptPath)
        let run = TabRun(backend: manager, config: TabRun.Config(busySeenTimeout: 30, turnTimeout: 30,
                                                                 pollInterval: 0.01))
        XCTAssertTrue(manager.inject(s.id, text: "go"))
        await until("prompt") { agent.heldPrompts == 1 }
        Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            agent.fake.finish()   // the container stopped mid-turn
        }
        let started = Date()
        let turn = await run.awaitTurn(tabID: s.id, path: path, fromOffset: 0)
        XCTAssertTrue(turn.agentExited)
        XCTAssertFalse(turn.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "returned on exit, not at turnTimeout")
        XCTAssertEqual(session(s.id)?.status, .shell)
        XCTAssertEqual(session(s.id)?.connectError, "the agent exited")
    }

    func testAgentDyingBeforeInitializeShowsAReasonAndReloadRecovers() async throws {
        let s = await readyTab(ScriptedAgent(capabilities: resume))
        let sid = try XCTUnwrap(s.claudeSessionID)
        await until("record") { manager.restorableSessions().first?.acpSessionID == "s1" }

        // The container is stopped: docker prints why on stderr and exits before `initialize` answers.
        let dead = ScriptedAgent(capabilities: resume)
        let log = SessionManager.acpLogURL(base: base, session: sid)
        dead.on("initialize") { [dead] _ in
            AcpLog.append("Error response from daemon: container c is not running", to: log)
            dead.fake.finish()
            return .hold
        }
        scripted.append(dead)
        let failed = try XCTUnwrap(manager.reload(s.id))
        await until("dead tab") { session(failed.id)?.status == .shell }
        await until("reason") { session(failed.id)?.connectError != nil }
        XCTAssertEqual(session(failed.id)?.connectError,
                       AcpSessionController.exitedBeforeStart
                           + ": Error response from daemon: container c is not running")
        XCTAssertEqual(manager.restorableSessions().first?.acpSessionID, "s1", "the tab stays restorable")
        XCTAssertEqual(manager.restorableSessions().first?.sessionID, sid)

        scripted.append(ScriptedAgent(capabilities: resume))
        let back = try XCTUnwrap(manager.reload(failed.id))
        await until("recovered") { session(back.id)?.status == .idle }
        XCTAssertNil(session(back.id)?.connectError)
        XCTAssertEqual(back.claudeSessionID, sid)
        XCTAssertEqual(launched.last?.params(of: "session/resume").first?["sessionId"]?.stringValue, "s1")
    }

    func testSessionStartSavesTheCatalogAndShowsTheOptionsOnTheTab() async {
        let store = AcpOptionCatalogStore(defaults: defaults)
        manager.acpOptionCatalog = store
        let s = await readyTab(advertisingAgent())
        XCTAssertEqual(store.load(agentID: ppt.id).map(\.id), ["mode", "model"])
        XCTAssertEqual(session(s.id)?.acpConfigOptions.map(\.currentValue), ["default", "claude-sonnet-4-6"])

        let error = await manager.setACPConfigOption(s.id, id: "model", value: "claude-opus-4-6")
        XCTAssertNil(error)
        XCTAssertEqual(session(s.id)?.acpConfigOptions.last?.currentValue, "claude-opus-4-6")
        XCTAssertEqual(launched.last?.params(of: "session/set_config_option").last?["configId"]?.stringValue, "model")
    }

    func testRefusedPickIsTheOptionNameAndTheAgentsMessage() async {
        let agent = advertisingAgent()
        agent.on("session/set_config_option") { _ in .error(-32602, "unknown model") }
        let s = await readyTab(agent)
        let error = await manager.setACPConfigOption(s.id, id: "model", value: "nope")
        XCTAssertEqual(error, "Could not set Model: unknown model")
    }

    func testRefusedStartingOptionIsTheRecordedReason() async {
        let agent = advertisingAgent()
        ppt.defaultConfigOptions = ["mode": "bypassPermissions"]
        agent.on("session/set_config_option") { _ in .error(-32603, "root needs IS_SANDBOX=1") }
        scripted.append(agent)
        let s = manager.commissionACP(agent: ppt, callsign: "x")
        await until("reason") { session(s.id)?.connectError != nil }
        XCTAssertEqual(session(s.id)?.connectError, "agent refused mode=bypassPermissions: root needs IS_SANDBOX=1")
    }

    // MARK: - Runner factory

    /// The default factory (not the fake): on this Mac git runs directly, bounded like an exec;
    /// elsewhere with no exec there is no runner at all.
    func testDefaultRunnerFactoryFollowsTheWorkspace() throws {
        let fresh = SessionManager(
            host: FakeTerminalHost(), claudeHome: base, executablePath: "/bin/echo",
            appearanceStore: SessionAppearanceStore(defaults: defaults),
            openSessionsStore: OpenSessionsStore(defaults: defaults), supportDir: base,
            touchedReposStore: TouchedReposStore(defaults: defaults))
        let mac = AcpAgentConfig(name: "m", launch: AcpCommand(command: "npx"), env: ["PATH": "/opt/x"], cwd: "/p")
        let local = try XCTUnwrap(fresh.acpRunnerFactory(mac) as? LocalCommandRunner)
        XCTAssertEqual(local.defaultTimeout, 5)
        XCTAssertEqual(local.environment?["PATH"], "/opt/x", "the agent's own PATH wins, as for its launch")
        var none = mac
        none.workspace = .elsewhere(exec: nil)
        XCTAssertNil(fresh.acpRunnerFactory(none))
        var exec = mac
        exec.workspace = .elsewhere(exec: AcpCommand(command: "ssh", args: ["h"]))
        let remote = try XCTUnwrap(fresh.acpRunnerFactory(exec) as? ExecCommandRunner)
        XCTAssertEqual(remote.exec, AcpCommand(command: "ssh", args: ["h"]))
        fresh.terminateAll()
    }

    // MARK: - Restore / reload

    func testRestoreKeepsACPRecordWhoseCwdIsNotOnTheMac() async {
        XCTAssertFalse(FileManager.default.fileExists(atPath: agentCwd))
        let local = UUID().uuidString.lowercased()
        let record = OpenSessionRecord(cwd: agentCwd, sessionID: local, callsign: "fix-bug",
                                       acpAgentName: "ppt", acpSessionID: "acp-9")
        guard case let .acp(agent, acpID) = manager.restorePlan(for: record) else {
            return XCTFail("ACP record not restored: \(manager.restorePlan(for: record))")
        }
        XCTAssertEqual(agent.name, "PPT")
        XCTAssertEqual(acpID, "acp-9")
        scripted.append(ScriptedAgent(capabilities: resume))
        let s = manager.restoreACP(record, agent: agent, acpSessionID: acpID)
        XCTAssertEqual(s.claudeSessionID, local)
        XCTAssertEqual(s.cwd, agentCwd)
        await until("restored") { session(s.id)?.status == .idle }
        XCTAssertEqual(launched.first?.params(of: "session/resume").first?["sessionId"]?.stringValue, "acp-9")
        XCTAssertFalse(launched.first?.methods.contains("session/new") ?? true)
    }

    func testRestorePlanSkipsUnknownAgentAndMissingFolder() {
        let unknown = OpenSessionRecord(cwd: agentCwd, sessionID: "a", callsign: "c",
                                        acpAgentName: "Gone", acpSessionID: "x")
        guard case let .skip(reason) = manager.restorePlan(for: unknown) else { return XCTFail("not skipped") }
        XCTAssertTrue(reason.contains("Gone"), reason)
        let pty = OpenSessionRecord(cwd: agentCwd, sessionID: "b", callsign: "c")
        guard case .skip = manager.restorePlan(for: pty) else { return XCTFail("PTY record with no folder kept") }
        let here = OpenSessionRecord(cwd: base.path, sessionID: "c", callsign: "c")
        XCTAssertEqual(manager.restorePlan(for: here), .pty(resume: false))
    }

    func testRestoreViaLoadDoesNotDuplicateTheMirror() async throws {
        let local = UUID().uuidString.lowercased()
        let mirror = TranscriptMirror.url(base: base, session: local)
        try FileManager.default.createDirectory(
            at: mirror.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"type\":\"user\"}\n{\"type\":\"assistant\"}\n".utf8).write(to: mirror)
        let agent = ScriptedAgent(capabilities: .object(["loadSession": .bool(true)]))
        agent.on("session/load") { [agent] p in
            agent.say("old reply", session: p["sessionId"]?.stringValue ?? "")
            return .result(.null)
        }
        scripted.append(agent)
        let record = OpenSessionRecord(cwd: agentCwd, sessionID: local, callsign: "c",
                                       acpAgentName: "PPT", acpSessionID: "acp-1")
        let s = manager.restoreACP(record, agent: ppt, acpSessionID: "acp-1")
        await until("restored") { session(s.id)?.status == .idle }
        XCTAssertTrue(manager.inject(s.id, text: "next"))
        await until("live prompt mirrored") { lines(mirror).count == 3 }
        XCTAssertFalse(lines(mirror).contains { $0.contains("old reply") }, "replay duplicated into the mirror")
    }

    func testRestoreViaLoadRebuildsAMissingMirror() async throws {
        let local = UUID().uuidString.lowercased()
        let mirror = TranscriptMirror.url(base: base, session: local)
        let agent = ScriptedAgent(capabilities: .object(["loadSession": .bool(true)]))
        agent.on("session/load") { [agent] p in
            agent.say("old reply", session: p["sessionId"]?.stringValue ?? "")
            return .result(.null)
        }
        scripted.append(agent)
        let record = OpenSessionRecord(cwd: agentCwd, sessionID: local, callsign: "c",
                                       acpAgentName: "PPT", acpSessionID: "acp-1")
        let s = manager.restoreACP(record, agent: ppt, acpSessionID: "acp-1")
        await until("restored") { session(s.id)?.status == .idle }
        await until("replay mirrored") { lines(mirror).contains { $0.contains("old reply") } }
    }

    func testReloadRestoresTheSameLocalSession() async throws {
        let first = ScriptedAgent(capabilities: resume)
        let s = await readyTab(first)
        await until("record") { manager.restorableSessions().first?.acpSessionID == "s1" }
        scripted.append(ScriptedAgent(capabilities: resume))
        let fresh = try XCTUnwrap(manager.reload(s.id))
        XCTAssertEqual(fresh.claudeSessionID, s.claudeSessionID)
        XCTAssertEqual(fresh.backend, .acp(agentName: "PPT"))
        await until("old terminated") { first.fake.terminated }
        await until("reloaded") { session(fresh.id)?.status == .idle }
        XCTAssertEqual(launched.last?.params(of: "session/resume").first?["sessionId"]?.stringValue, "s1")
        XCTAssertEqual(manager.sessions.count, 1)
    }

    // MARK: - Fork / delete / import

    func testForkUsesSessionForkWhenAdvertised() async throws {
        let other = await readyTab(callsign: "other")
        let source = await readyTab(ScriptedAgent(capabilities: fork), callsign: "src")
        manager.move(source.id, before: other.id)
        scripted.append(ScriptedAgent(capabilities: fork))
        manager.fork(source.id)
        XCTAssertEqual(manager.sessions.count, 3)
        let forked = manager.sessions[1]
        XCTAssertEqual(manager.sessions.map(\.id), [source.id, forked.id, other.id])
        XCTAssertEqual(forked.displayTitle, "src-(fork)")
        XCTAssertEqual(forked.backend, .acp(agentName: "PPT"))
        XCTAssertNotEqual(forked.claudeSessionID, source.claudeSessionID)
        XCTAssertEqual(manager.selectedID, forked.id)
        await until("forked") { session(forked.id)?.acpSessionID == "s2" }
        XCTAssertEqual(launched.last?.params(of: "session/fork").first?["sessionId"]?.stringValue, "s1")
    }

    func testForkNoOpWithoutCapability() async {
        let source = await readyTab()
        manager.fork(source.id)
        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertEqual(launched.count, 1)
    }

    func testDeleteClosesAndTerminates() async {
        let agent = ScriptedAgent(capabilities: close)
        let s = await readyTab(agent)
        await until("record") { !manager.restorableSessions().isEmpty }
        manager.delete(s.id)
        await until("terminated") { agent.fake.terminated }
        XCTAssertTrue(agent.methods.contains("session/close"))
        XCTAssertEqual(agent.params(of: "session/close").first?["sessionId"]?.stringValue, "s1")
        XCTAssertTrue(manager.restorableSessions().isEmpty)
        XCTAssertTrue(manager.sessions.isEmpty)
    }

    func testImportListsSessionsAndSkipsAlreadyOpen() async {
        let open = ScriptedAgent()
        open.on("session/new") { _ in .result(.object(["sessionId": .string("a1")])) }
        _ = await readyTab(open)
        let lister = ScriptedAgent(capabilities: list)
        lister.on("session/list") { _ in
            .result(.object(["sessions": .array([
                .object(["sessionId": .string("a1"), "cwd": .string("/w"), "title": .string("One")]),
                .object(["sessionId": .string("a2"), "cwd": .string("/w"), "title": .string("Two")]),
            ])]))
        }
        scripted.append(lister)
        let found = await manager.importACPSessions(agent: ppt)
        XCTAssertEqual(found.map(\.acpSessionID), ["a2"])
        XCTAssertEqual(found.map(\.title), ["Two"])
        XCTAssertEqual(lister.methods, ["initialize", "session/list"], "never session/new as a probe")
        XCTAssertEqual(lister.params(of: "session/list").first?["cwd"]?.stringValue, agentCwd)
        XCTAssertTrue(lister.fake.terminated)
        XCTAssertEqual(manager.sessions.count, 1, "import only lists; it opens nothing")
    }

    func testImportWithoutListCapabilityAsksNothing() async {
        let lister = ScriptedAgent()
        scripted.append(lister)
        let found = await manager.importACPSessions(agent: ppt)
        XCTAssertTrue(found.isEmpty)
        XCTAssertEqual(lister.methods, ["initialize"])
        XCTAssertTrue(lister.fake.terminated)
    }

    // MARK: - Capability record / git through exec

    func testCapabilityRecordNegotiatedThenProbedThroughExec() async {
        execRunner = ExecFake(ghAuthed: false)
        let s = await readyTab(ScriptedAgent(capabilities: fork))
        await until("probes") { session(s.id)?.acpCapabilities?.git != nil }
        let record = session(s.id)?.acpCapabilities
        XCTAssertEqual(record?.negotiated.fork, true)
        XCTAssertEqual(record?.hasExec, true)
        XCTAssertEqual(record?.git, true)
        XCTAssertEqual(record?.gh, true)
        XCTAssertEqual(record?.ghAuthed, false)
        XCTAssertEqual(record?.isEnabled(.branch), true)
        XCTAssertEqual(record?.reason(.prWatch), "gh is not logged in in the agent's environment")
    }

    func testBranchRefreshRunsThroughTheTabsExecRunner() async {
        let s = await readyTab()
        await until("probes") { session(s.id)?.acpCapabilities?.git == true }
        XCTAssertEqual(manager.gitAccess(for: try! XCTUnwrap(session(s.id)))?.interval, 5)
        manager.refreshGitBranch(for: s.id)
        await until("branch") { session(s.id)?.gitBranch == "feature-x" }
        XCTAssertTrue(execRunner?.calls.contains(["git", "-C", agentCwd, "symbolic-ref", "--short", "HEAD"]) ?? false)
    }

    func testNoExecLeavesRecordUnprobedAndBranchAlone() async {
        execRunner = nil
        let s = await readyTab()
        await until("record") { session(s.id)?.acpCapabilities != nil }
        let record = session(s.id)?.acpCapabilities
        XCTAssertNil(record?.git)
        XCTAssertEqual(record?.hasExec, false)
        XCTAssertEqual(record?.reason(.branch), "No exec command configured for this agent")
        XCTAssertNil(manager.gitAccess(for: try! XCTUnwrap(session(s.id))))
        manager.refreshGitBranch(for: s.id)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(session(s.id)?.gitBranch, "the Mac's git must never answer for the agent's cwd")
    }

    func testPtyTabKeepsLocalGitOnTheTwoSecondThrottle() {
        let s = AgentSession(callsign: "x", cwd: "/tmp")
        XCTAssertEqual(manager.gitAccess(for: s)?.interval, 2)
        XCTAssertTrue(manager.gitAccess(for: s)?.runner is LocalCommandRunner)
    }

    // MARK: - Permission / elicitation into the chat, queue, test connection, import

    private let permissionParams: JSONValue = .object([
        "sessionId": .string("s1"),
        "toolCall": .object(["title": .string("Run rm -rf build")]),
        "options": .array([
            .object(["optionId": .string("once"), "kind": .string("allow_once"), "name": .string("Allow")]),
            .object(["optionId": .string("no"), "kind": .string("reject_once"), "name": .string("Reject")]),
        ]),
    ])

    private func chatItems(_ s: AgentSession) -> [ChatItem] {
        ChatHistory.live(base: base, session: s.claudeSessionID ?? "", transcriptPath: s.transcriptPath).items
    }

    /// A permission request becomes the PTY tab's permission card (a `.needs` ledger event)
    /// and a "needs you" notification; it is never answered on its own, and Allow closes it.
    func testPermissionRequestShowsTheCardNotifiesAndAllowClosesIt() async throws {
        var posted: [(NotificationKind, String, String)] = []
        manager.postNotification = { _, kind, title, body in posted.append((kind, title, body)) }
        let agent = ScriptedAgent()
        let s = await readyTab(agent)
        XCTAssertTrue(manager.send(s.id, text: "go"))
        await until("prompt sent") { agent.heldPrompts == 1 }
        agent.ask(id: "p1", method: "session/request_permission", params: permissionParams)
        await until("card") { chatItems(s).contains { if case .needs(_, _, _, true) = $0 { true } else { false } } }
        guard case let .needs(_, text, _, _)? = chatItems(s).last else { return XCTFail("no needs card") }
        XCTAssertEqual(text, "Run rm -rf build")
        XCTAssertEqual(posted.map(\.0), [.needsInput])
        XCTAssertEqual(posted.first?.1, "@fix-bug needs you")
        XCTAssertEqual(posted.first?.2, "Run rm -rf build")
        XCTAssertNil(agent.reply(to: "p1"), "never auto-approved")

        XCTAssertTrue(manager.allowPermission(s.id))
        await until("allowed") { agent.reply(to: "p1") != nil }
        XCTAssertEqual(agent.reply(to: "p1")?["result"]?["outcome"]?["optionId"]?.stringValue, "once")
        await until("card closed") {
            !chatItems(s).contains { if case .needs(_, _, _, true) = $0 { true } else { false } }
        }
    }

    /// `end_turn` is the ACP moment of claude's `idle_prompt`: the same "needs you" note, through
    /// the one gate (which suppresses it for the tab being viewed). Other stop reasons say nothing.
    func testEndTurnPostsTheNeedsYouNotificationAndCancelDoesNot() async {
        var posted: [(UUID, NotificationKind, String, String)] = []
        manager.postNotification = { id, kind, title, body in posted.append((id, kind, title, body)) }
        let agent = ScriptedAgent()
        let s = await readyTab(agent)
        XCTAssertTrue(manager.send(s.id, text: "go"))
        await until("prompt sent") { agent.heldPrompts == 1 }
        agent.endPrompt()
        await until("idle") { session(s.id)?.status == .idle && posted.count == 1 }
        XCTAssertEqual(posted.first?.0, s.id)
        XCTAssertEqual(posted.first?.1, .needsInput)
        XCTAssertEqual(posted.first?.2, "@fix-bug needs you")
        XCTAssertEqual(posted.first?.3, "The agent is waiting for you")

        XCTAssertTrue(manager.send(s.id, text: "again"))
        await until("second prompt") { agent.heldPrompts == 1 }
        agent.endPrompt("cancelled")
        await until("idle again") { session(s.id)?.status == .idle }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(posted.count, 1, "a cancelled turn is the user's own doing — no note")
    }

    /// An `end_turn` that the tab immediately continues (a queued message) is not the agent waiting
    /// on the user: the note comes only once the queue has drained and the tab is idle.
    func testNeedsYouWaitsForTheQueueToDrain() async {
        var posted = 0
        manager.postNotification = { _, _, _, _ in posted += 1 }
        let agent = ScriptedAgent()
        let s = await readyTab(agent)
        XCTAssertTrue(manager.send(s.id, text: "one"))
        await until("first prompt") { agent.heldPrompts == 1 }
        XCTAssertTrue(manager.send(s.id, text: "two"))
        agent.endPrompt()
        await until("queued prompt sent") { agent.prompts().count == 2 }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(posted, 0, "the queue continues the turn")
        agent.endPrompt()
        await until("idle") { session(s.id)?.status == .idle && posted == 1 }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(posted, 1)
    }

    /// An ACP tab takes a prompt for certain — queued until the handshake is done counts. So a
    /// TabRun delivering into a tab still `.unknown` past its wait sends the prompt ONCE: no
    /// "did the transcript gain it?" check, and no retry queueing copies behind it.
    func testTabRunDeliversOnceIntoAnACPTabStillConnecting() async throws {
        let agent = ScriptedAgent()
        agent.on("initialize") { _ in .hold }
        scripted.append(agent)
        let s = manager.commissionACP(agent: ppt, callsign: "slow")
        let run = TabRun(backend: manager, config: TabRun.Config(
            pollInterval: 0.01, injectReadyTimeout: 0.05, injectVerifyTimeout: 0.05, injectMaxAttempts: 3))
        let path = try XCTUnwrap(manager.transcriptPath(tabID: s.id))
        let landed = await run.deliver("do the thing", tabID: s.id, path: path, baselineUserCount: 0)
        XCTAssertTrue(landed)
        XCTAssertEqual(session(s.id)?.status, .unknown)
        XCTAssertEqual(session(s.id)?.acpQueued, ["do the thing"])
    }

    /// A Stop block's follow-up (here the goal review) goes out as the next prompt, but Admiral
    /// wrote it: Chat shows it as Admiral's, not the user's — while the user's own prompt stays theirs.
    func testAStopFollowUpShowsInChatAsAdmirals() async throws {
        let agent = ScriptedAgent()
        let s = await readyTab(agent)
        let sid = try XCTUnwrap(s.claudeSessionID)
        guard case let .success(goals) = SessionGoals.make(from: ["ship it"]) else { return XCTFail("fixture") }
        GoalsStore(base: base).set(goals, forSession: sid)
        XCTAssertTrue(manager.send(s.id, text: "go"))
        await until("prompt sent") { agent.heldPrompts == 1 }
        agent.endPrompt()
        await until("follow-up sent") { agent.prompts().count == 2 && agent.heldPrompts == 1 }
        let followUp = try XCTUnwrap(agent.prompts().last)
        let prompts = chatItems(s).compactMap { item -> (String, String?)? in
            if case let .prompt(_, text, source, _) = item { return (text, source) }
            return nil
        }
        XCTAssertEqual(prompts.map(\.0), ["go", followUp])
        XCTAssertEqual(prompts.map(\.1), [nil, "admiral"])
    }

    /// Deny is the card's interrupt: the request is cancelled and the card closes.
    func testDenyCancelsThePermissionAndClosesTheCard() async {
        let agent = ScriptedAgent()
        let s = await readyTab(agent)
        XCTAssertTrue(manager.send(s.id, text: "go"))
        await until("prompt sent") { agent.heldPrompts == 1 }
        agent.ask(id: "p1", method: "session/request_permission", params: permissionParams)
        await until("card") { ChatHistory.live(base: base, session: s.claudeSessionID!, transcriptPath: nil).isWaiting }
        manager.interrupt(s.id)
        await until("cancelled") { agent.reply(to: "p1") != nil }
        XCTAssertEqual(agent.reply(to: "p1")?["result"]?["outcome"]?["outcome"]?.stringValue, "cancelled")
        await until("card closed") {
            !ChatHistory.live(base: base, session: s.claudeSessionID!, transcriptPath: nil).isWaiting
        }
    }

    /// An elicitation is the AskUserQuestion card; its answers go back as the elicitation's
    /// response — not typed in as a prompt — and the card closes.
    func testElicitationShowsTheQuestionCardAndIsAnsweredAsTheResponse() async throws {
        var posted: [NotificationKind] = []
        manager.postNotification = { _, kind, _, _ in posted.append(kind) }
        let agent = ScriptedAgent()
        let s = await readyTab(agent)
        XCTAssertTrue(manager.send(s.id, text: "go"))
        await until("prompt sent") { agent.heldPrompts == 1 }
        agent.ask(id: "e1", method: "elicitation/create", params: .object([
            "sessionId": .string("s1"), "mode": .string("form"), "message": .string("Pick a database"),
            "requestedSchema": .object(["type": .string("object"), "properties": .object([
                "db": .object(["type": .string("string"), "title": .string("DB"),
                               "enum": .array([.string("pg"), .string("my")])]),
            ])]),
        ]))
        let sid = try XCTUnwrap(s.claudeSessionID)
        await until("card") { ChatHistory.live(base: base, session: sid, transcriptPath: nil).openAsk != nil }
        let questions = try XCTUnwrap(
            ChatHistory.live(base: base, session: sid, transcriptPath: nil).openAsk?.questions)
        XCTAssertEqual(questions.first?.header, "DB")
        XCTAssertEqual(posted, [.question])

        XCTAssertTrue(manager.answerAsk(s.id, questions: questions, answers: ["pg"]))
        await until("answered") { agent.reply(to: "e1") != nil }
        XCTAssertEqual(agent.reply(to: "e1")?["result"]?["action"]?.stringValue, "accept")
        XCTAssertEqual(agent.reply(to: "e1")?["result"]?["content"]?["db"]?.stringValue, "pg")
        XCTAssertEqual(agent.prompts().count, 1, "the answer is not a typed prompt")
        await until("card closed") { ChatHistory.live(base: base, session: sid, transcriptPath: nil).openAsk == nil }
    }

    func testQueuedInputShowsOnTheTab() async {
        let agent = ScriptedAgent()
        let s = await readyTab(agent)
        XCTAssertTrue(manager.send(s.id, text: "first"))
        await until("prompt sent") { agent.heldPrompts == 1 }
        XCTAssertTrue(manager.send(s.id, text: "second"))
        await until("queued") { session(s.id)?.acpQueued == ["second"] }
        agent.endPrompt()
        await until("drained") { session(s.id)?.acpQueued == [] }
    }

    /// Test connection: initialize only — never session/new — then the agent is ended; the
    /// result is the record a tab would start with, exec probes included.
    func testConnectionTestInitializesOnlyAndProbes() async throws {
        let agent = ScriptedAgent(capabilities: fork)
        agent.on("initialize") { _ in
            .result(.object([
                "agentCapabilities": self.fork,
                "agentInfo": .object(["name": .string("claude-agent-acp"), "version": .string("0.100.0")]),
            ]))
        }
        scripted.append(agent)
        let result = await manager.testACPConnection(ppt)
        guard case let .connected(record) = result else { return XCTFail("expected connected, got \(result)") }
        XCTAssertEqual(record.negotiated.agentName, "claude-agent-acp")
        XCTAssertEqual(record.negotiated.agentVersion, "0.100.0")
        XCTAssertTrue(record.isEnabled(.fork))
        XCTAssertEqual(record.git, true)
        XCTAssertEqual(record.ghAuthed, true)
        XCTAssertEqual(agent.methods, ["initialize"], "never session/new as a health check")
        XCTAssertTrue(agent.fake.terminated)
        XCTAssertTrue(manager.sessions.isEmpty, "a test opens no tab")
    }

    func testConnectionTestFailureCarriesTheAgentsStderr() async throws {
        let dead = ScriptedAgent()
        let log = SessionManager.acpLogURL(base: base, session: "test-\(ppt.id.uuidString.lowercased())")
        dead.on("initialize") { [dead] _ in
            AcpLog.append("Error response from daemon: container c is not running", to: log)
            dead.fake.finish()
            return .hold
        }
        scripted.append(dead)
        let result = await manager.testACPConnection(ppt)
        XCTAssertEqual(result, .failed(
            message: "the agent exited or did not answer initialize: "
                + "Error response from daemon: container c is not running",
            log: log))
    }

    /// A real launch of a command that is on no PATH: the message carries env's own words and
    /// the hint to give the full path.
    func testConnectionTestOfAMissingCommandSaysWhyAndHowToFixIt() async throws {
        manager.acpTransportFactory = {
            try ProcessAcpTransport(command: $0.launch, env: $0.env, logURL: $1, loginPath: { nil })
        }
        let missing = AcpAgentConfig(name: "Gone", launch: AcpCommand(command: "no-such-acp-agent"), cwd: agentCwd)
        let result = await manager.testACPConnection(missing)
        guard case let .failed(message, _) = result else { return XCTFail("expected failed, got \(result)") }
        XCTAssertEqual(message, "the agent exited or did not answer initialize: "
            + "env: no-such-acp-agent: No such file or directory"
            + " \u{2014} is `no-such-acp-agent` on your PATH?"
            + " Use its full path (e.g. /usr/local/bin/no-such-acp-agent)")
    }

    /// `docker exec` writes an OCI failure to STDOUT, then exits 127 — that line is the reason,
    /// and since it is not env's own complaint, no Mac-PATH hint.
    func testConnectionTestFailureCarriesANonJSONStdoutLine() async throws {
        let dir = try ToolDir(name: "fake-docker", script: """
            echo 'OCI runtime exec failed: exec: "claude-agent-acp": executable file not found in $PATH'
            exit 127
            """)
        defer { dir.remove() }
        manager.acpTransportFactory = {
            try ProcessAcpTransport(command: $0.launch, env: $0.env, logURL: $1, loginPath: { dir.url.path })
        }
        let box = AcpAgentConfig(name: "Box", launch: AcpCommand(command: "fake-docker"), cwd: agentCwd)
        let result = await manager.testACPConnection(box)
        guard case let .failed(message, _) = result else { return XCTFail("expected failed, got \(result)") }
        XCTAssertEqual(message, "the agent exited or did not answer initialize: "
            + #"OCI runtime exec failed: exec: "claude-agent-acp": executable file not found in $PATH"#)
    }

    func testOpeningAnImportedSessionTwiceSelectsTheOpenTab() async {
        scripted.append(ScriptedAgent(capabilities: resume))
        let first = manager.openImportedACP(agent: ppt, acpSessionID: "a7", title: "Fix the login bug")
        XCTAssertEqual(first.displayTitle, "Fix-the-login-bug")
        await until("restored") { session(first.id)?.status == .idle }
        XCTAssertEqual(launched.last?.params(of: "session/resume").first?["sessionId"]?.stringValue, "a7")
        let other = await readyTab(callsign: "other")
        XCTAssertEqual(manager.selectedID, other.id)
        let again = manager.openImportedACP(agent: ppt, acpSessionID: "a7", title: "Fix the login bug")
        XCTAssertEqual(again.id, first.id)
        XCTAssertEqual(manager.selectedID, first.id)
        XCTAssertEqual(manager.sessions.count, 2)
    }

    /// The fork gate reads the tab's record — the same source as the menu item.
    func testForkGateReadsTheCapabilityRecord() async {
        let source = await readyTab(ScriptedAgent(capabilities: fork))
        manager.update(source.id) { $0.acpCapabilities?.negotiated.fork = false }
        manager.fork(source.id)
        XCTAssertEqual(manager.sessions.count, 1, "the record says no fork")
    }
}
