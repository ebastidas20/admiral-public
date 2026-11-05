import XCTest
@testable import AdmiralCore

/// Records every hook call; `followUps` are handed out, one per `afterTurn`.
private final class RecordingHooks: AcpTurnHooks, @unchecked Sendable {
    private let lock = NSLock()
    private var _before: [String] = []
    private var _after: [String] = []
    private var followUps: [String]

    init(followUps: [String] = []) { self.followUps = followUps }

    var before: [String] { lock.withLock { _before } }
    var after: [String] { lock.withLock { _after } }

    func beforePrompt(_ text: String) async -> String {
        lock.withLock { _before.append(text) }
        return "[reminder] " + text
    }

    func afterTurn(lastAssistantMessage: String) async -> String? {
        lock.withLock {
            _after.append(lastAssistantMessage)
            return followUps.isEmpty ? nil : followUps.removeFirst()
        }
    }

    func onToolCall(_ update: AcpUpdate) async {}
    func onCompaction() async {}
}

/// Hooks that stop inside `beforePrompt` / `afterTurn` until the test opens their gate, so a
/// test can act while the controller is mid-hook. Text passes through unchanged.
private final class GatedHooks: AcpTurnHooks, @unchecked Sendable {
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var isOpen: Bool
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private(set) var entered = 0
        init(open: Bool) { isOpen = open }
        func wait() async {
            await withCheckedContinuation { c in
                let resumeNow = lock.withLock { () -> Bool in
                    entered += 1
                    if isOpen { return true }
                    waiters.append(c)
                    return false
                }
                if resumeNow { c.resume() }
            }
        }
        func open() {
            let w = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                isOpen = true
                defer { waiters = [] }
                return waiters
            }
            w.forEach { $0.resume() }
        }
        var waiting: Int { lock.withLock { entered } }
    }

    let before: Gate
    let after: Gate
    private let lock = NSLock()
    private var _hooked: [String] = []
    private var followUps: [String]

    init(gateBefore: Bool = false, gateAfter: Bool = false, followUps: [String] = []) {
        before = Gate(open: !gateBefore)
        after = Gate(open: !gateAfter)
        self.followUps = followUps
    }

    var hooked: [String] { lock.withLock { _hooked } }

    func beforePrompt(_ text: String) async -> String {
        lock.withLock { _hooked.append(text) }
        await before.wait()
        return text
    }

    func afterTurn(lastAssistantMessage: String) async -> String? {
        await after.wait()
        return lock.withLock { followUps.isEmpty ? nil : followUps.removeFirst() }
    }

    func onToolCall(_ update: AcpUpdate) async {}
    func onCompaction() async {}
}

@MainActor
final class AcpSessionControllerTests: XCTestCase {
    private var dir: URL!
    private var statuses: [SessionStatus] = []
    private var phases: [AcpSessionController.Phase] = []
    private var stops: [AcpStopReason] = []
    private var permissions: [String] = []
    private var questions: [[AskQuestion]] = []
    private var started: (id: String, caps: AcpCapabilities)?

    override func setUp() async throws {
        try await super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("acp-ctl-\(UUID().uuidString)")
        statuses = []
        phases = []
        stops = []
        permissions = []
        questions = []
        started = nil
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private let steering: JSONValue = .object(["_meta": .object(["steering": .object(["supported": .bool(true)])])])

    private func make(
        _ agent: ScriptedAgent,
        defaultMode: String? = "bypassPermissions",
        options: [String: String] = [:],
        hooks: AcpTurnHooks? = nil
    ) -> AcpSessionController {
        let config = AcpAgentConfig(
            name: "PPT", launch: AcpCommand(command: "docker"), cwd: "/workspace",
            defaultMode: defaultMode, defaultConfigOptions: options)
        let connection = JSONRPCConnection(transport: agent, log: { _ in })
        let mirror = TranscriptMirror(
            url: TranscriptMirror.url(base: dir, session: "adm"), sessionID: "adm", cwd: "/workspace")
        let events = AcpSessionController.Events(
            status: { [unowned self] in statuses.append($0) },
            phase: { [unowned self] in phases.append($0) },
            sessionStarted: { [unowned self] id, caps, _ in started = (id, caps) },
            turnEnded: { [unowned self] in stops.append($0) },
            permissionRequested: { [unowned self] in permissions.append($0) },
            question: { [unowned self] in questions.append($0) },
            update: { _ in })
        return AcpSessionController(
            config: config, connection: connection, mirror: mirror,
            mcpServer: AcpMCPServer(name: "admiral", url: "http://host.docker.internal:4142/mcp", bearer: "t"),
            hooks: hooks, events: events)
    }

    /// Bounded polling: yields to the main actor until `condition` holds or 2 s pass.
    private func until(
        _ what: String = "condition",
        file: StaticString = #filePath, line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for \(what)", file: file, line: line) }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func ready(_ agent: ScriptedAgent, hooks: AcpTurnHooks? = nil) async -> AcpSessionController {
        let c = make(agent, hooks: hooks)
        await c.start(.new)
        XCTAssertEqual(phases.last, .ready)
        return c
    }

    // MARK: - Handshake

    func testNewSessionHandshakeOrder() async {
        let agent = ScriptedAgent(capabilities: .object(["mcpCapabilities": .object(["http": .bool(true)])]))
        let c = make(agent)
        await c.start(.new)
        XCTAssertEqual(agent.methods, ["initialize", "session/new", "session/set_mode"])
        let new = agent.params(of: "session/new").first
        XCTAssertEqual(new?["cwd"]?.stringValue, "/workspace")
        let server = new?["mcpServers"]?.arrayValue?.first
        XCTAssertEqual(server?["name"]?.stringValue, "admiral")
        XCTAssertEqual(server?["type"]?.stringValue, "http")
        let mode = agent.params(of: "session/set_mode").first
        XCTAssertEqual(mode?["modeId"]?.stringValue, "bypassPermissions")
        XCTAssertEqual(mode?["sessionId"]?.stringValue, "s1")
        XCTAssertEqual(phases, [.ready])
        XCTAssertEqual(started?.id, "s1")
        XCTAssertEqual(statuses.last, .idle)
    }

    /// An agent that does not advertise HTTP MCP is never handed the HTTP bridge server.
    func testNoMCPServerForAnAgentWithoutHTTP() async {
        let agent = ScriptedAgent()
        let c = make(agent)
        await c.start(.new)
        XCTAssertEqual(agent.params(of: "session/new").first?["mcpServers"]?.arrayValue?.count, 0)
        XCTAssertTrue(c.offersBridge, "the bridge was offered; the agent just cannot use it")
    }

    func testDefaultConfigOptionsAreAppliedAfterMode() async {
        let agent = ScriptedAgent()
        let c = make(agent, options: ["model": "opus"])
        await c.start(.new)
        XCTAssertEqual(agent.methods, ["initialize", "session/new", "session/set_mode", "session/set_config_option"])
        let opt = agent.params(of: "session/set_config_option").first
        XCTAssertEqual(opt?["configId"]?.stringValue, "model")
        XCTAssertEqual(opt?["value"]?.stringValue, "opus")
    }

    func testRefusedBypassModeFailsTheTab() async {
        let agent = ScriptedAgent()
        agent.on("session/set_mode") { _ in .error(-32603, "root needs IS_SANDBOX=1") }
        let c = make(agent, options: ["model": "opus"])
        await c.start(.new)
        guard case let .failed(message)? = phases.last else { return XCTFail("not failed: \(phases)") }
        XCTAssertTrue(message.contains("root needs IS_SANDBOX=1"), message)
        XCTAssertFalse(agent.methods.contains("session/set_config_option"), "must not continue past a refused mode")
        XCTAssertFalse(c.deliver("hi"))
    }

    func testRestorePrefersResumeThenLoad() async {
        let both = ScriptedAgent(capabilities: .object([
            "loadSession": .bool(true), "sessionCapabilities": .object(["resume": .object([:])]),
        ]))
        await make(both).start(.restore(acpSessionID: "old"))
        XCTAssertTrue(both.methods.contains("session/resume"))
        XCTAssertFalse(both.methods.contains("session/load"))
        XCTAssertEqual(both.params(of: "session/resume").first?["sessionId"]?.stringValue, "old")
        XCTAssertEqual(phases.last, .ready)
        XCTAssertEqual(started?.id, "old")

        phases = []
        let loadOnly = ScriptedAgent(capabilities: .object(["loadSession": .bool(true)]))
        await make(loadOnly).start(.restore(acpSessionID: "old"))
        XCTAssertTrue(loadOnly.methods.contains("session/load"))
        XCTAssertFalse(loadOnly.methods.contains("session/resume"))
        XCTAssertEqual(phases.last, .ready)

        phases = []
        let neither = ScriptedAgent()
        await make(neither).start(.restore(acpSessionID: "old"))
        XCTAssertEqual(phases.last, .failed("agent cannot restore sessions"))
        XCTAssertEqual(neither.methods, ["initialize"])
    }

    func testForkRequiresCapability() async {
        let agent = ScriptedAgent(capabilities: .object(["sessionCapabilities": .object(["fork": .object([:])])]))
        await make(agent).start(.fork(acpSessionID: "s1"))
        XCTAssertEqual(agent.params(of: "session/fork").first?["sessionId"]?.stringValue, "s1")
        XCTAssertEqual(started?.id, "s2")

        phases = []
        let none = ScriptedAgent()
        await make(none).start(.fork(acpSessionID: "s1"))
        XCTAssertEqual(phases.last, .failed("agent cannot fork sessions"))
    }

    // MARK: - Turns

    func testPromptSetsBusyThenIdle() async {
        let agent = ScriptedAgent()
        let c = await ready(agent)
        XCTAssertTrue(c.submitTyped("hello"))
        XCTAssertEqual(statuses.last, .busy)
        await until("prompt sent") { agent.heldPrompts == 1 }
        XCTAssertEqual(agent.prompts(), ["hello"])
        agent.say("hi there")
        agent.endPrompt()
        await until("idle") { statuses.last == .idle }
        XCTAssertEqual(stops, [.endTurn])
    }

    func testSteeringUsedWhenAdvertisedWhileBusy() async {
        let agent = ScriptedAgent(capabilities: steering)
        let c = await ready(agent)
        XCTAssertTrue(c.deliver("first"))
        await until("prompt sent") { agent.heldPrompts == 1 }
        XCTAssertTrue(c.deliver("second"))
        await until("steering sent") { agent.methods.contains("_session/steering") }
        let steer = agent.params(of: "_session/steering").first
        XCTAssertEqual(steer?["prompt"]?.arrayValue?.first?["text"]?.stringValue, "second")
        XCTAssertEqual(steer?["_meta"]?["idleBehavior"]?.stringValue, "promptRequired")
        XCTAssertEqual(c.queued, [])
        XCTAssertEqual(agent.prompts(), ["first"])
    }

    func testSteeringPromptRequiredFallsBackToQueue() async {
        let agent = ScriptedAgent(capabilities: steering)
        agent.on("_session/steering") { _ in .result(.object(["outcome": .string("promptRequired")])) }
        let c = await ready(agent)
        XCTAssertTrue(c.deliver("first"))
        await until("prompt sent") { agent.heldPrompts == 1 }
        XCTAssertTrue(c.deliver("second"))
        await until("queued") { c.queued == ["second"] }
        agent.endPrompt()
        await until("queued prompt sent") { agent.prompts() == ["first", "second"] }
    }

    func testQueuedMessagesDrainInOrderAfterEndTurn() async {
        let agent = ScriptedAgent()
        let c = await ready(agent)
        XCTAssertTrue(c.deliver("first"))
        await until("prompt sent") { agent.heldPrompts == 1 }
        XCTAssertTrue(c.deliver("one"))
        XCTAssertTrue(c.deliver("two"))
        XCTAssertEqual(c.queued, ["one", "two"])
        XCTAssertFalse(agent.methods.contains("_session/steering"))

        agent.endPrompt()
        await until("#1 sent") { agent.prompts() == ["first", "one"] }
        XCTAssertEqual(c.queued, ["two"])
        XCTAssertEqual(statuses.last, .busy)

        agent.endPrompt()
        await until("#2 sent") { agent.prompts() == ["first", "one", "two"] }
        XCTAssertEqual(c.queued, [])
        agent.endPrompt()
        await until("idle") { statuses.last == .idle }
    }

    func testCancelKeepsQueue() async {
        let agent = ScriptedAgent()
        let c = await ready(agent)
        XCTAssertTrue(c.deliver("first"))
        await until("prompt sent") { agent.heldPrompts == 1 }
        XCTAssertTrue(c.deliver("later"))
        c.interrupt()
        await until("cancel sent") { agent.methods.contains("session/cancel") }
        XCTAssertEqual(agent.params(of: "session/cancel").first?["sessionId"]?.stringValue, "s1")
        XCTAssertEqual(c.queued, ["later"])

        agent.endPrompt("cancelled")
        await until("idle") { statuses.last == .idle }
        XCTAssertEqual(stops, [.cancelled])
        XCTAssertEqual(c.queued, ["later"], "an interrupt keeps the queue and does not drain it")
        XCTAssertEqual(agent.prompts(), ["first"])
    }

    // MARK: - Held requests

    private let permissionParams: JSONValue = .object([
        "sessionId": .string("s1"),
        "toolCall": .object(["toolCallId": .string("t1"), "title": .string("Run rm -rf build")]),
        "options": .array([
            .object(["optionId": .string("always"), "name": .string("Always"), "kind": .string("allow_always")]),
            .object(["optionId": .string("once"), "name": .string("Allow"), "kind": .string("allow_once")]),
            .object(["optionId": .string("no"), "name": .string("Reject"), "kind": .string("reject_once")]),
        ]),
    ])

    func testPermissionRequestIsHeldUntilAllowed() async {
        let agent = ScriptedAgent()
        let c = await ready(agent)
        XCTAssertTrue(c.deliver("go"))
        await until("prompt sent") { agent.heldPrompts == 1 }
        agent.ask(id: "p1", method: "session/request_permission", params: permissionParams)
        await until("permission surfaced") { permissions == ["Run rm -rf build"] }
        // Give a (wrong) auto-reply every chance to land before asserting there is none.
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertNil(agent.reply(to: "p1"), "a permission request must never be answered on its own")
        XCTAssertEqual(statuses.last, .busy)

        XCTAssertTrue(c.allowPermission())
        await until("reply sent") { agent.reply(to: "p1") != nil }
        let outcome = agent.reply(to: "p1")?["result"]?["outcome"]
        XCTAssertEqual(outcome?["outcome"]?.stringValue, "selected")
        XCTAssertEqual(outcome?["optionId"]?.stringValue, "once")
        XCTAssertFalse(c.allowPermission(), "nothing left to allow")
    }

    func testInterruptCancelsOpenPermission() async {
        let agent = ScriptedAgent()
        let c = await ready(agent)
        XCTAssertTrue(c.deliver("go"))
        await until("prompt sent") { agent.heldPrompts == 1 }
        agent.ask(id: "p1", method: "session/request_permission", params: permissionParams)
        await until("permission surfaced") { permissions.count == 1 }
        c.interrupt()
        await until("reply sent") { agent.reply(to: "p1") != nil }
        XCTAssertEqual(agent.reply(to: "p1")?["result"]?["outcome"]?["outcome"]?.stringValue, "cancelled")
    }

    func testElicitationAnsweredWithFormContent() async {
        let agent = ScriptedAgent()
        let c = await ready(agent)
        XCTAssertTrue(c.deliver("go"))
        await until("prompt sent") { agent.heldPrompts == 1 }
        agent.ask(id: "e1", method: "elicitation/create", params: .object([
            "sessionId": .string("s1"),
            "mode": .string("form"),
            "message": .string("Pick a database"),
            "requestedSchema": .object([
                "type": .string("object"),
                "properties": .object([
                    "db": .object([
                        "type": .string("string"), "title": .string("DB"),
                        "description": .string("Which DB?"),
                        "oneOf": .array([
                            .object(["const": .string("pg"), "title": .string("Postgres")]),
                            .object(["const": .string("my"), "title": .string("MySQL")]),
                        ]),
                    ]),
                    "checks": .object([
                        "type": .string("array"), "title": .string("Checks"),
                        "items": .object(["enum": .array([.string("lint"), .string("test")])]),
                    ]),
                    "notes": .object(["type": .string("string"), "title": .string("Notes")]),
                    "force": .object(["type": .string("boolean"), "title": .string("Force")]),
                ]),
                "required": .array([.string("db"), .string("checks")]),
            ]),
        ]))
        await until("question surfaced") { questions.count == 1 }
        let asked = questions[0]
        XCTAssertEqual(asked.map(\.header), ["DB", "Checks", "Force", "Notes"])
        XCTAssertEqual(asked[0].question, "Which DB?")
        XCTAssertEqual(asked[0].options.map(\.label), ["Postgres", "MySQL"])
        XCTAssertTrue(asked[1].multiSelect)
        XCTAssertEqual(asked[2].options.map(\.label), ["Yes", "No"])
        XCTAssertEqual(asked[3].options, [])
        XCTAssertNil(agent.reply(to: "e1"))

        XCTAssertTrue(c.answer(questions: asked, answers: ["Postgres", "lint, test", "No", "be careful"]))
        await until("reply sent") { agent.reply(to: "e1") != nil }
        let result = agent.reply(to: "e1")?["result"]
        XCTAssertEqual(result?["action"]?.stringValue, "accept")
        XCTAssertEqual(result?["content"], .object([
            "db": .string("pg"),
            "checks": .array([.string("lint"), .string("test")]),
            "force": .bool(false),
            "notes": .string("be careful"),
        ]))
        XCTAssertFalse(c.answer(questions: asked, answers: []), "nothing left to answer")
    }

    // MARK: - Hooks

    func testPromptPassesThroughBeforePromptHook() async {
        let agent = ScriptedAgent()
        let hooks = RecordingHooks()
        let c = await ready(agent, hooks: hooks)
        XCTAssertTrue(c.submitTyped("hello"))
        await until("prompt sent") { agent.heldPrompts == 1 }
        XCTAssertEqual(hooks.before, ["hello"])
        XCTAssertEqual(agent.prompts(), ["[reminder] hello"])
    }

    func testAfterTurnFollowUpSentBeforeQueue() async {
        let agent = ScriptedAgent()
        let hooks = RecordingHooks(followUps: ["please report done"])
        let c = await ready(agent, hooks: hooks)
        XCTAssertTrue(c.deliver("work"))
        await until("prompt sent") { agent.heldPrompts == 1 }
        XCTAssertTrue(c.deliver("queued"))
        agent.say("did ")
        agent.say("it")
        agent.endPrompt()
        await until("follow-up sent") { agent.prompts().count == 2 }
        XCTAssertEqual(hooks.after, ["did it"])
        // The follow-up is a Stop continuation, not a user prompt: it skips `beforePrompt`.
        XCTAssertEqual(hooks.before, ["work"])
        XCTAssertEqual(agent.prompts(), ["[reminder] work", "please report done"])
        XCTAssertEqual(c.queued, ["queued"])

        agent.endPrompt()
        await until("queue drained") { agent.prompts().count == 3 }
        XCTAssertEqual(agent.prompts().last, "[reminder] queued")
        XCTAssertEqual(hooks.after, ["did it", ""])
    }

    /// With the real adapter: one user prompt with a goal open earns exactly one review
    /// follow-up, then the tab goes idle. A follow-up that ran UserPromptSubmit would reset the
    /// review budget and loop review → follow-up → review forever.
    func testOpenGoalEarnsOneReviewFollowUpThenIdle() async {
        guard case let .success(goals) = SessionGoals.make(from: ["ship it"]) else {
            return XCTFail("fixture must be valid")
        }
        GoalsStore(base: dir).set(goals, forSession: "adm")
        let review = (try? JSONSerialization.jsonObject(
            with: Data(GoalsReminder.stopReviewJSON(for: goals).utf8)) as? [String: Any])?["reason"] as? String
        let hooks = AcpHookAdapter(base: dir, token: "tok", sessionID: "adm", cwd: "/workspace", runner: nil)
        let agent = ScriptedAgent()
        let c = await ready(agent, hooks: hooks)
        XCTAssertTrue(c.submitTyped("work"))
        await until("prompt sent") { agent.heldPrompts == 1 }
        agent.endPrompt()
        await until("review follow-up sent") { agent.prompts().count == 2 }
        XCTAssertEqual(agent.prompts().last, review)
        agent.endPrompt()
        await until("idle") { statuses.last == .idle && agent.heldPrompts == 0 }
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(agent.prompts().count, 2, "no second review: \(agent.prompts())")
        XCTAssertEqual(statuses.last, .idle)
        XCTAssertTrue(agent.prompts()[0].hasSuffix("\n\nwork"), "the user prompt carried the reminder")
    }

    // MARK: - Close

    func testTransportEOFEndsTurnAndMarksShell() async {
        let agent = ScriptedAgent()
        let c = await ready(agent)
        XCTAssertTrue(c.deliver("go"))
        await until("prompt sent") { agent.heldPrompts == 1 }
        agent.ask(id: "p1", method: "session/request_permission", params: permissionParams)
        await until("permission surfaced") { permissions.count == 1 }
        agent.say("partial")
        agent.fake.finish()
        await until("shell") { statuses.last == .shell }
        XCTAssertEqual(phases.last, .ended)
        XCTAssertFalse(stops.contains(.endTurn))
        XCTAssertFalse(c.deliver("after close"))
        XCTAssertFalse(c.submitTyped("after close"))
        XCTAssertFalse(c.allowPermission(), "held requests were released on close")
        let url = TranscriptMirror.url(base: dir, session: "adm")
        let transcript = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        XCTAssertTrue(transcript.contains("partial"), "the mirror flushed the cut-off turn")
    }

    // MARK: - Mirror shows the raw prompt (fix round, R9)

    private func mirroredUserTexts() -> [String] {
        let url = TranscriptMirror.url(base: dir, session: "adm")
        let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return raw.split(separator: "\n").compactMap { line -> String? in
            let v = (try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))) ?? .null
            guard v["type"]?.stringValue == "user" else { return nil }
            return v["message"]?["content"]?.stringValue
        }
    }

    func testMirrorShowsTheRawPromptAndTheWireCarriesTheHookContext() async {
        let agent = ScriptedAgent()
        let hooks = RecordingHooks()
        let c = await ready(agent, hooks: hooks)
        XCTAssertTrue(c.deliver("hi"))
        await until("prompt sent") { agent.heldPrompts == 1 }
        XCTAssertEqual(agent.prompts(), ["[reminder] hi"])
        XCTAssertEqual(mirroredUserTexts(), ["hi"])
    }

    func testABouncedSteerIsMirroredRawOnceAndHookedOnce() async {
        let agent = ScriptedAgent(capabilities: steering)
        agent.on("_session/steering") { _ in .result(.object(["outcome": .string("promptRequired")])) }
        let hooks = RecordingHooks()
        let c = await ready(agent, hooks: hooks)
        XCTAssertTrue(c.deliver("first"))
        await until("prompt sent") { agent.heldPrompts == 1 }
        XCTAssertTrue(c.deliver("second"))
        await until("bounced") { c.queued == ["second"] }
        agent.endPrompt()
        await until("queued prompt sent") { agent.prompts().count == 2 }
        XCTAssertEqual(agent.prompts(), ["[reminder] first", "[reminder] second"])
        XCTAssertEqual(hooks.before, ["first", "second"], "the bounced steer is not hooked twice")
        XCTAssertEqual(mirroredUserTexts(), ["first", "second"])
    }

    func testAPromptPutBackByAnInterruptIsMirroredRawWhenItGoes() async {
        let agent = ScriptedAgent()
        let gated = GatedHooks(gateBefore: true)
        let c = await ready(agent, hooks: gated)
        XCTAssertTrue(c.deliver("held"))
        await until("in hook") { gated.before.waiting == 1 }
        c.interrupt()
        gated.before.open()
        await until("put back") { c.queued == ["held"] }
        XCTAssertTrue(c.deliver("next"))
        await until("sent") { agent.heldPrompts == 1 }
        XCTAssertEqual(mirroredUserTexts(), ["held"])
        XCTAssertEqual(c.queued, ["next"])
    }

    func testTransportClosingBeforeInitializeAnswersFailsTheLaunch() async {
        let agent = ScriptedAgent()
        agent.on("initialize") { [agent] _ in
            agent.fake.finish()
            return .hold
        }
        let c = make(agent)
        await c.start(.new)
        await until("failed") { if case .failed = c.phase { true } else { phases.last == .ended } }
        guard case let .failed(message)? = phases.first else { return XCTFail("not failed first: \(phases)") }
        XCTAssertEqual(message, AcpSessionController.exitedBeforeStart)
    }

    func testTerminateClosesSessionWhenAdvertised() async {
        let agent = ScriptedAgent(capabilities: .object(["sessionCapabilities": .object(["close": .object([:])])]))
        let c = await ready(agent)
        c.terminate()
        await until("terminated") { agent.fake.terminated }
        XCTAssertTrue(agent.methods.contains("session/close"))
        await until("ended") { phases.last == .ended }
    }

    func testDriverHasNoScreenOrKeys() async {
        let c = await ready(ScriptedAgent())
        XCTAssertNil(c.readScreen())
        XCTAssertFalse(c.sendKeys("\u{1b}"))
    }

    // MARK: - Ordering and interrupts (fix round 1)

    func testDeliverAfterCancelSendsOldestQueuedFirst() async {
        let agent = ScriptedAgent()
        let c = await ready(agent)
        XCTAssertTrue(c.deliver("first"))
        await until("prompt sent") { agent.heldPrompts == 1 }
        XCTAssertTrue(c.deliver("old"))
        c.interrupt()
        agent.endPrompt("cancelled")
        await until("idle") { statuses.last == .idle }
        XCTAssertEqual(c.queued, ["old"])

        XCTAssertTrue(c.deliver("new"))
        await until("oldest sent") { agent.prompts().count == 2 }
        XCTAssertEqual(agent.prompts(), ["first", "old"])
        XCTAssertEqual(c.queued, ["new"])
        agent.endPrompt()
        await until("newest sent") { agent.prompts().count == 3 }
        XCTAssertEqual(agent.prompts().last, "new")
    }

    func testSteeringDoesNotOvertakeQueuedItems() async {
        let agent = ScriptedAgent(capabilities: steering)
        let hooks = GatedHooks(gateAfter: true, followUps: ["follow"])
        let c = await ready(agent, hooks: hooks)
        XCTAssertTrue(c.deliver("work"))
        await until("prompt sent") { agent.heldPrompts == 1 }
        agent.endPrompt()
        await until("settling") { hooks.after.waiting == 1 }
        XCTAssertTrue(c.deliver("old"))
        XCTAssertEqual(c.queued, ["old"], "nothing to steer into while settling")
        hooks.after.open()
        await until("follow-up sent") { agent.prompts() == ["work", "follow"] }
        XCTAssertTrue(c.deliver("new"))
        await until("both steered") { agent.params(of: "_session/steering").count == 2 }
        let steered = agent.params(of: "_session/steering")
            .compactMap { $0["prompt"]?.arrayValue?.first?["text"]?.stringValue }
        XCTAssertEqual(steered, ["old", "new"])
        XCTAssertEqual(c.queued, [])
    }

    func testBouncedSteerStaysAheadOfNewerItems() async {
        let agent = ScriptedAgent(capabilities: steering)
        agent.on("_session/steering") { _ in .result(.object(["outcome": .string("promptRequired")])) }
        let c = await ready(agent)
        XCTAssertTrue(c.deliver("work"))
        await until("prompt sent") { agent.heldPrompts == 1 }
        XCTAssertTrue(c.deliver("a"))
        await until("bounced") { c.queued == ["a"] }
        XCTAssertTrue(c.deliver("b"))
        XCTAssertEqual(c.queued, ["a", "b"])
        XCTAssertEqual(agent.params(of: "_session/steering").count, 1, "no steering after a bounce this turn")
        agent.endPrompt()
        await until("a sent") { agent.prompts() == ["work", "a"] }
    }

    func testInterruptBeforePromptIsSentPutsItBack() async {
        let agent = ScriptedAgent()
        let hooks = GatedHooks(gateBefore: true)
        let c = await ready(agent, hooks: hooks)
        XCTAssertTrue(c.deliver("x"))
        await until("in the hook") { hooks.before.waiting == 1 }
        c.interrupt()
        hooks.before.open()
        await until("idle") { statuses.last == .idle }
        XCTAssertEqual(agent.prompts(), [], "an interrupted prompt is not sent")
        XCTAssertEqual(c.queued, ["x"], "and not lost")

        XCTAssertTrue(c.deliver("y"))
        await until("x sent") { agent.prompts() == ["x"] }
        XCTAssertEqual(c.queued, ["y"])
        XCTAssertEqual(hooks.hooked, ["x"], "the put-back prompt is not hooked twice")
    }

    func testInterruptWhileSettlingDropsFollowUp() async {
        let agent = ScriptedAgent()
        let hooks = GatedHooks(gateAfter: true, followUps: ["follow"])
        let c = await ready(agent, hooks: hooks)
        XCTAssertTrue(c.deliver("work"))
        await until("prompt sent") { agent.heldPrompts == 1 }
        agent.endPrompt()
        await until("settling") { hooks.after.waiting == 1 }
        c.interrupt()
        hooks.after.open()
        await until("idle") { statuses.last == .idle }
        XCTAssertEqual(agent.prompts(), ["work"], "the follow-up is dropped after a stop")
    }
}
