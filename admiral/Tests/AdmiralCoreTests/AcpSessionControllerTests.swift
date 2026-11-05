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
    private var settles = 0
    private var permissions: [String] = []
    private var questions: [[AskQuestion]] = []
    /// Every `requestResolved` and `permissionRequested`, in order: "resolved" / the title.
    private var requestLog: [String] = []
    private var queues: [[String]] = []
    private var started: (id: String, caps: AcpCapabilities)?
    private var optionChanges: [[AcpConfigOption]] = []
    private var logLines: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("acp-ctl-\(UUID().uuidString)")
        statuses = []
        phases = []
        stops = []
        settles = 0
        permissions = []
        questions = []
        requestLog = []
        queues = []
        started = nil
        optionChanges = []
        logLines = []
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private let steering: JSONValue = .object(["_meta": .object(["steering": .object(["supported": .bool(true)])])])

    private func make(
        _ agent: ScriptedAgent,
        options: [String: String] = [:],
        hooks: AcpTurnHooks? = nil
    ) -> AcpSessionController {
        let config = AcpAgentConfig(
            name: "PPT", launch: AcpCommand(command: "docker"), cwd: "/workspace",
            defaultConfigOptions: options)
        let connection = JSONRPCConnection(transport: agent, log: { _ in })
        let mirror = TranscriptMirror(
            url: TranscriptMirror.url(base: dir, session: "adm"), sessionID: "adm", cwd: "/workspace")
        let events = AcpSessionController.Events(
            status: { [unowned self] in statuses.append($0) },
            phase: { [unowned self] in phases.append($0) },
            sessionStarted: { [unowned self] id, caps, _ in started = (id, caps) },
            turnEnded: { [unowned self] in stops.append($0) },
            settledIdle: { [unowned self] in settles += 1 },
            permissionRequested: { [unowned self] in
                permissions.append($0)
                requestLog.append($0)
            },
            question: { [unowned self] in questions.append($0) },
            requestResolved: { [unowned self] in requestLog.append("resolved") },
            queueChanged: { [unowned self] in queues.append($0) },
            update: { _ in },
            configOptionsChanged: { [unowned self] in optionChanges.append($0) },
            log: { [unowned self] in logLines.append($0) })
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
        XCTAssertEqual(agent.methods, ["initialize", "session/new"], "no starting mode unless configured")
        let new = agent.params(of: "session/new").first
        XCTAssertEqual(new?["cwd"]?.stringValue, "/workspace")
        let server = new?["mcpServers"]?.arrayValue?.first
        XCTAssertEqual(server?["name"]?.stringValue, "admiral")
        XCTAssertEqual(server?["type"]?.stringValue, "http")
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

    private static func json(_ s: String) -> JSONValue {
        (try? JSONDecoder().decode(JSONValue.self, from: Data(s.utf8))) ?? .null
    }

    /// claude-agent-acp's `session/new` result: `mode` and `model` as select config options.
    private static let advertised = json(AcpConfigOptionsTests.claudeAgentACP)

    private static let legacyNew = json("""
        {"sessionId":"s1","modes":{"currentModeId":"a",
         "availableModes":[{"id":"a","name":"Ask"},{"id":"b","name":"Code"}]}}
        """)

    /// An agent whose `session/new` advertises claude-agent-acp's options, and whose
    /// `set_config_option` answers with the full list, the chosen value current.
    private func optionsAgent(_ capabilities: JSONValue = .object([:])) -> ScriptedAgent {
        let agent = ScriptedAgent(capabilities: capabilities)
        agent.on("session/new") { _ in .result(Self.advertised) }
        var current = Self.advertised
        agent.on("session/set_config_option") { p in
            guard case var .object(o) = current, case var .array(list)? = o["configOptions"] else {
                return .result(.null)
            }
            for i in list.indices where list[i]["id"] == p["configId"] {
                guard case var .object(option) = list[i] else { continue }
                option["currentValue"] = p["value"]
                list[i] = .object(option)
            }
            o["configOptions"] = .array(list)
            current = .object(o)
            return .result(.object(["configOptions": .array(list)]))
        }
        return agent
    }

    func testStartingOptionsOnNewSetAdvertisedIDsInIDOrder() async {
        let agent = optionsAgent()
        let c = make(agent, options: ["model": "claude-opus-4-6", "mode": "plan"])
        await c.start(.new)
        XCTAssertEqual(phases.last, .ready)
        XCTAssertEqual(agent.methods, [
            "initialize", "session/new", "session/set_config_option", "session/set_config_option",
        ])
        XCTAssertEqual(agent.params(of: "session/set_config_option").map { $0["configId"]?.stringValue },
                       ["mode", "model"])
        XCTAssertEqual(agent.params(of: "session/set_config_option").map { $0["value"]?.stringValue },
                       ["plan", "claude-opus-4-6"])
        XCTAssertEqual(c.configOptions.map(\.currentValue), ["plan", "claude-opus-4-6"],
                       "the response list replaces")
        XCTAssertEqual(optionChanges, [c.configOptions], "fired once, after sessionStarted")
    }

    func testUnadvertisedStartingOptionIsSkippedAndLogged() async {
        let agent = optionsAgent()
        let c = make(agent, options: ["effort": "high", "mode": "dontAsk"])
        await c.start(.new)
        XCTAssertEqual(phases.last, .ready, "a stale catalog never fails the tab")
        XCTAssertEqual(agent.methods, ["initialize", "session/new"])
        XCTAssertEqual(logLines, [
            "acp: starting option effort not offered by the agent \u{2014} skipped",
            "acp: starting option mode=dontAsk not offered by the agent \u{2014} skipped",
        ])
        XCTAssertEqual(c.configOptions.map(\.id), ["mode", "model"])
    }

    func testLegacyAgentModeGoesThroughSetMode() async {
        let agent = ScriptedAgent()
        agent.on("session/new") { _ in .result(Self.legacyNew) }
        let c = make(agent, options: ["mode": "b"])
        await c.start(.new)
        XCTAssertEqual(agent.methods, ["initialize", "session/new", "session/set_mode"])
        XCTAssertEqual(agent.params(of: "session/set_mode").first?["modeId"]?.stringValue, "b")
        XCTAssertEqual(c.configOptions.first?.currentValue, "b")
        XCTAssertEqual(c.configOptions.first?.setter, .legacyMode)
    }

    func testRestoreAppliesNoStartingOptions() async {
        let agent = optionsAgent(.object(["sessionCapabilities": .object(["resume": .object([:])])]))
        agent.on("session/resume") { _ in .result(Self.advertised) }
        let c = make(agent, options: ["mode": "plan", "model": "claude-opus-4-6"])
        await c.start(.restore(acpSessionID: "s1"))
        XCTAssertEqual(phases.last, .ready)
        XCTAssertFalse(agent.methods.contains("session/set_config_option"))
        XCTAssertFalse(agent.methods.contains("session/set_mode"))
        XCTAssertEqual(c.configOptions.first?.currentValue, "default", "the agent's restored mode stands")
    }

    func testForkAppliesStartingOptions() async {
        let agent = optionsAgent(.object(["sessionCapabilities": .object(["fork": .object([:])])]))
        agent.on("session/fork") { _ in .result(Self.advertised) }
        let c = make(agent, options: ["mode": "plan"])
        await c.start(.fork(acpSessionID: "s1"))
        XCTAssertEqual(phases.last, .ready)
        XCTAssertEqual(agent.params(of: "session/set_config_option").first?["configId"]?.stringValue, "mode")
        XCTAssertEqual(agent.params(of: "session/set_config_option").first?["value"]?.stringValue, "plan")
    }

    func testConfigOptionUpdateAndCurrentModeUpdateReachTheTab() async {
        let agent = optionsAgent()
        let c = await ready(agent)
        agent.notify(update: Self.json("""
            {"sessionUpdate":"config_option_update","configOptions":[
             {"id":"model","name":"Model","type":"select","currentValue":"x","options":[{"value":"x","name":"X"}]}]}
            """))
        await until("config update") { optionChanges.last?.map(\.id) == ["model"] }
        XCTAssertEqual(c.configOptions.map(\.currentValue), ["x"])

        let full = optionsAgent()
        let d = await ready(full)
        full.notify(update: Self.json(#"{"sessionUpdate":"current_mode_update","currentModeId":"plan"}"#))
        await until("mode update") { d.configOptions.first?.currentValue == "plan" }
        XCTAssertEqual(optionChanges.last?.first?.currentValue, "plan")
    }

    func testSetConfigOptionUsesTheOptionsSetter() async throws {
        let agent = optionsAgent()
        let c = await ready(agent)
        optionChanges = []
        try await c.setConfigOption(id: "model", value: "claude-opus-4-6")
        XCTAssertEqual(agent.params(of: "session/set_config_option").last?["configId"]?.stringValue, "model")
        XCTAssertEqual(c.configOptions[1].currentValue, "claude-opus-4-6")
        XCTAssertEqual(optionChanges, [c.configOptions])

        let legacy = ScriptedAgent()
        legacy.on("session/new") { _ in .result(Self.legacyNew) }
        let l = await ready(legacy)
        try await l.setConfigOption(id: "mode", value: "b")
        XCTAssertEqual(legacy.params(of: "session/set_mode").first?["modeId"]?.stringValue, "b")
        XCTAssertFalse(legacy.methods.contains("session/set_config_option"))
        XCTAssertEqual(l.configOptions.first?.currentValue, "b")

        agent.on("session/set_config_option") { _ in .error(-32602, "unknown model") }
        do {
            try await c.setConfigOption(id: "model", value: "nope")
            XCTFail("a refusal throws")
        } catch {
            XCTAssertEqual(error as? JSONRPCError, JSONRPCError(code: -32602, message: "unknown model"))
        }
    }

    /// The agent pushes a new mode (e.g. a plan approved) while a model pick is in flight; the
    /// pick's answer, an older snapshot, must not put the old mode back.
    func testSetAnswerDoesNotOverwriteANewerPush() async throws {
        let agent = optionsAgent()
        let c = await ready(agent)
        agent.on("session/set_config_option") { _ in .hold }
        let pick = Task { try await c.setConfigOption(id: "model", value: "claude-opus-4-6") }
        await until("pick in flight") { agent.held("session/set_config_option") == 1 }
        agent.notify(update: Self.json(#"{"sessionUpdate":"current_mode_update","currentModeId":"acceptEdits"}"#))
        await until("push applied") { c.configOptions.first?.currentValue == "acceptEdits" }

        guard case let .object(o) = Self.advertised, case var .array(stale)? = o["configOptions"],
              case var .object(model) = stale[1] else { return XCTFail("fixture") }
        model["currentValue"] = .string("claude-opus-4-6")
        stale[1] = .object(model)
        agent.release("session/set_config_option", result: .object(["configOptions": .array(stale)]))
        try await pick.value
        XCTAssertEqual(c.configOptions.map(\.currentValue), ["acceptEdits", "claude-opus-4-6"],
                       "the push's mode stands; only the picked value is patched")
    }

    func testRefusedStartingOptionFailsTheTab() async {
        let agent = optionsAgent()
        agent.on("session/set_config_option") { _ in .error(-32603, "root needs IS_SANDBOX=1") }
        let c = make(agent, options: ["mode": "bypassPermissions", "model": "opus"])
        await c.start(.new)
        guard case let .failed(message)? = phases.last else { return XCTFail("not failed: \(phases)") }
        XCTAssertTrue(message.contains("root needs IS_SANDBOX=1"), message)
        XCTAssertEqual(agent.methods.filter { $0 == "session/set_config_option" }.count, 1,
                       "must not continue past a refused option")
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

    /// `@file` mentions ride as `resource_link` blocks after the text — on a prompt and on a steer.
    func testLinksGoOutOnThePromptAndOnASteer() async {
        let agent = ScriptedAgent(capabilities: steering)
        let c = await ready(agent)
        let a = AcpResourceLink(path: "src/a.swift", cwd: "/workspace")
        let b = AcpResourceLink(path: "docs/b c.md", cwd: "/workspace")
        XCTAssertTrue(c.accept("first", links: [a]))
        await until("prompt sent") { agent.heldPrompts == 1 }
        XCTAssertTrue(c.accept("second", links: [b]))
        await until("steering sent") { agent.methods.contains("_session/steering") }
        let prompt = agent.params(of: "session/prompt").first?["prompt"]?.arrayValue ?? []
        XCTAssertEqual(prompt.count, 2)
        XCTAssertEqual(prompt.last?["type"]?.stringValue, "resource_link")
        XCTAssertEqual(prompt.last?["uri"]?.stringValue, "file:///workspace/src/a.swift")
        XCTAssertEqual(prompt.last?["name"]?.stringValue, "src/a.swift")
        let steer = agent.params(of: "_session/steering").first?["prompt"]?.arrayValue ?? []
        XCTAssertEqual(steer.first?["text"]?.stringValue, "second")
        XCTAssertEqual(steer.last?["uri"]?.stringValue, "file:///workspace/docs/b%20c.md")
        XCTAssertEqual(c.queued, [])
    }

    /// A steer the agent bounced goes out later as a prompt — with its links still on it.
    func testBouncedSteerKeepsItsLinks() async {
        let agent = ScriptedAgent(capabilities: steering)
        agent.on("_session/steering") { _ in .result(.object(["outcome": .string("promptRequired")])) }
        let c = await ready(agent)
        XCTAssertTrue(c.deliver("first"))
        await until("prompt sent") { agent.heldPrompts == 1 }
        XCTAssertTrue(c.accept("second", links: [AcpResourceLink(path: "a", cwd: "/w")]))
        await until("queued") { c.queued == ["second"] }
        agent.endPrompt()
        await until("queued prompt sent") { agent.prompts() == ["first", "second"] }
        let second = agent.params(of: "session/prompt").last?["prompt"]?.arrayValue ?? []
        XCTAssertEqual(second.last?["uri"]?.stringValue, "file:///w/a")
    }

    /// A steer is not run as a command, so a slash command waits for the turn to end.
    func testSlashCommandWaitsForTheTurnInsteadOfSteering() async {
        let agent = ScriptedAgent(capabilities: steering)
        let c = await ready(agent)
        XCTAssertTrue(c.deliver("first"))
        await until("prompt sent") { agent.heldPrompts == 1 }
        XCTAssertTrue(c.deliver("/compact"))
        XCTAssertTrue(c.deliver("after"))
        XCTAssertEqual(c.queued, ["/compact", "after"], "nothing overtakes the command")
        XCTAssertFalse(agent.methods.contains("_session/steering"))
        agent.endPrompt()
        await until("command sent as a prompt") { agent.prompts() == ["first", "/compact"] }
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

    /// One card at a time: a second permission request waits until the first is answered, and
    /// the answer is reported (closing the first card) before the second is surfaced.
    func testPermissionRequestsSurfaceOneAtATimeAfterResolution() async {
        let agent = ScriptedAgent()
        let c = await ready(agent)
        XCTAssertTrue(c.deliver("go"))
        await until("prompt sent") { agent.heldPrompts == 1 }
        agent.ask(id: "p1", method: "session/request_permission", params: permissionParams)
        var second = permissionParams
        if case var .object(o) = second {
            o["toolCall"] = .object(["title": .string("Run make deploy")])
            second = .object(o)
        }
        agent.ask(id: "p2", method: "session/request_permission", params: second)
        await until("first surfaced") { permissions.count == 1 }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(permissions, ["Run rm -rf build"], "the second waits for the first")

        XCTAssertTrue(c.allowPermission())
        await until("second surfaced") { permissions.count == 2 }
        XCTAssertEqual(requestLog, ["Run rm -rf build", "resolved", "Run make deploy"])
        c.interrupt()
        await until("p2 cancelled") { agent.reply(to: "p2") != nil }
        XCTAssertEqual(requestLog.last, "resolved", "a cancel closes the open card too")
    }

    func testQueueChangesAreReported() async {
        let agent = ScriptedAgent()
        let c = await ready(agent)
        XCTAssertTrue(c.deliver("one"))
        await until("prompt sent") { agent.heldPrompts == 1 }
        XCTAssertTrue(c.deliver("two"))
        await until("queued") { queues.last == ["two"] }
        XCTAssertEqual(c.queued, ["two"])
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

    /// claude-agent-acp's "Other" is a `<key>_custom` text field beside the choice: it is the
    /// card's Other box, not a second question, so a typed answer alone completes the card.
    func testElicitationCustomCompanionFoldsIntoItsChoice() async {
        let agent = ScriptedAgent()
        let c = await ready(agent)
        XCTAssertTrue(c.deliver("go"))
        await until("prompt sent") { agent.heldPrompts == 1 }
        func ask(_ id: String) {
            agent.ask(id: id, method: "elicitation/create", params: .object([
                "sessionId": .string("s1"), "mode": .string("form"), "message": .string("Next?"),
                "requestedSchema": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "question_0": .object([
                            "type": .string("string"), "title": .string("Next item"),
                            "oneOf": .array([
                                .object(["const": .string("a"), "title": .string("Alpha")]),
                                .object(["const": .string("b"), "title": .string("Beta")]),
                            ]),
                        ]),
                        "question_0_custom": .object([
                            "type": .string("string"), "title": .string("Other"),
                            "description": .string("Type your own answer"),
                        ]),
                    ]),
                ]),
            ]))
        }
        ask("e1")
        await until("first question surfaced") { questions.count == 1 }
        XCTAssertEqual(questions[0].map(\.header), ["Next item"], "the companion is no question of its own")
        XCTAssertEqual(questions[0][0].options.map(\.label), ["Alpha", "Beta"])
        XCTAssertTrue(c.answer(questions: questions[0], answers: ["something else"]))
        await until("first reply") { agent.reply(to: "e1") != nil }
        XCTAssertEqual(agent.reply(to: "e1")?["result"]?["content"],
                       .object(["question_0_custom": .string("something else")]))

        ask("e2")
        await until("second question surfaced") { questions.count == 2 }
        XCTAssertTrue(c.answer(questions: questions[1], answers: ["Beta"]))
        await until("second reply") { agent.reply(to: "e2") != nil }
        XCTAssertEqual(agent.reply(to: "e2")?["result"]?["content"], .object(["question_0": .string("b")]))
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

    /// A slash command runs only when the prompt starts with it: no reminder in front of it.
    func testSlashCommandSkipsBeforePromptHook() async {
        let agent = ScriptedAgent()
        let hooks = RecordingHooks()
        let c = await ready(agent, hooks: hooks)
        XCTAssertTrue(c.submitTyped("/clear"))
        await until("prompt sent") { agent.heldPrompts == 1 }
        XCTAssertEqual(hooks.before, [])
        XCTAssertEqual(agent.prompts(), ["/clear"])
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

    func testSettledIdleFiresOncePerIdleEndTurnNotBetweenFollowUpOrQueue() async {
        let agent = ScriptedAgent()
        let hooks = RecordingHooks(followUps: ["review"])
        let c = await ready(agent, hooks: hooks)
        XCTAssertTrue(c.deliver("work"))
        await until("prompt sent") { agent.heldPrompts == 1 }
        XCTAssertTrue(c.deliver("queued"))
        agent.endPrompt()
        await until("follow-up sent") { agent.prompts().count == 2 }
        XCTAssertEqual(settles, 0, "a follow-up continues the turn")
        agent.endPrompt()
        await until("queue drained") { agent.prompts().count == 3 }
        XCTAssertEqual(settles, 0, "a queued prompt continues the turn")
        agent.endPrompt()
        await until("idle") { settles == 1 }
        XCTAssertEqual(stops, [.endTurn, .endTurn, .endTurn])
    }

    func testSettledIdleSilentForACancelledTurn() async {
        let agent = ScriptedAgent()
        let c = await ready(agent)
        XCTAssertTrue(c.deliver("work"))
        await until("prompt sent") { agent.heldPrompts == 1 }
        agent.endPrompt("cancelled")
        await until("idle") { statuses.last == .idle }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(settles, 0)
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
