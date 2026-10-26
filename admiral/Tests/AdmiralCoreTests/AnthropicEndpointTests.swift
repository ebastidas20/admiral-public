import XCTest
@testable import AdmiralCore

/// Scripted backend: statuses pop per liveStatus() call (last repeats), and an
/// onPoll hook lets a test append transcript bytes mid-turn.
@MainActor
final class FakeAnthropicBackend: AnthropicBackend {
    var tabs: [String: AnthropicTab] = [:]
    var paths: [UUID: String] = [:]
    var tabsBySession: [String: AnthropicTab] = [:]
    private(set) var created: [(sid: String, cwd: String, model: String?, clientTools: [ClientToolSpec]?)] = []
    /// Override creation (nil result = simulate failure). Default registers a managed tab.
    var createResult: ((String, String, String?, [ClientToolSpec]?) -> AnthropicTab?)?
    var statuses: [SessionStatus] = [.idle]
    private(set) var injected: [(id: UUID, text: String)] = []
    var onPoll: (Int) -> Void = { _ in }   // called with the liveStatus call count
    var onInject: (Int) -> Void = { _ in } // called with the inject call count
    private var polls = 0
    var clientToolTabs: Set<UUID> = []
    private(set) var installedTools: [UUID: [ClientToolSpec]] = [:]
    let clientToolBroker = ClientToolBroker()

    func tab(named name: String) -> AnthropicTab? {
        tabs.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
    func tab(sessionID: String) -> AnthropicTab? { tabsBySession[sessionID.lowercased()] }
    func createScratchTab(sessionID: String, cwd: String, model: String?,
                          clientTools: [ClientToolSpec]?) -> AnthropicTab? {
        created.append((sessionID, cwd, model, clientTools))
        if let make = createResult { return make(sessionID, cwd, model, clientTools) }
        let tab = AnthropicTab(id: UUID(), name: "quirky_otter", isManaged: true)
        tabsBySession[sessionID.lowercased()] = tab
        if clientTools != nil { clientToolTabs.insert(tab.id) }
        return tab
    }
    func sessionToken(tabID: UUID) -> String? { "token-\(tabID.uuidString)" }
    func clientToolsEnabled(tabID: UUID) -> Bool { clientToolTabs.contains(tabID) }
    func installClientTools(tabID: UUID, tools: [ClientToolSpec]) {
        guard clientToolTabs.contains(tabID) else { return }
        installedTools[tabID] = tools
    }
    func inject(tabID: UUID, text: String) {
        injected.append((tabID, text))
        onInject(injected.count)
    }
    func liveStatus(tabID: UUID) -> SessionStatus {
        polls += 1
        onPoll(polls)
        return polls <= statuses.count ? statuses[polls - 1] : statuses.last ?? .unknown
    }
    func transcriptPath(tabID: UUID) -> String? { paths[tabID] }

    private(set) var armedSpecs: [UUID: StructuredOutputSpec] = [:]
    var soStates: [UUID: StructuredOutputState] = [:]
    private(set) var clearedSO: [UUID] = []

    func armStructuredOutput(tabID: UUID, spec: StructuredOutputSpec) {
        armedSpecs[tabID] = spec
        soStates[tabID] = StructuredOutputState(schema: spec.schema, delivery: spec.delivery,
                                                toolName: spec.toolName)
    }
    func structuredOutputState(tabID: UUID, type: ArmType) -> StructuredOutputState? {
        soStates[tabID]
    }
    func clearStructuredOutput(tabID: UUID, type: ArmType) {
        clearedSO.append(tabID)
        soStates[tabID] = nil
    }
}

@MainActor
final class AnthropicEndpointTests: XCTestCase {
    private var backend: FakeAnthropicBackend!
    private var endpoint: AnthropicEndpoint!
    private var tabID: UUID!
    private var transcript: URL!

    /// Fast test clock: 10ms polls; busy fallback after 3 polls, 529 after ~5, cap ~20.
    private static let cfg = AnthropicEndpoint.Config(
        busyWaitTimeout: 0.05, busySeenTimeout: 0.03, turnTimeout: 0.2,
        pollInterval: 0.01, pingInterval: 10,
        injectReadyTimeout: 0.05, injectVerifyTimeout: 0.02, injectMaxAttempts: 3)

    /// A key some requests still send. The server does not require it.
    static let apiToken = "adm_endpoint_test"

    override func setUp() async throws {
        backend = FakeAnthropicBackend()
        endpoint = AnthropicEndpoint(backend: backend, config: Self.cfg)
        tabID = UUID()
        backend.tabs["Worker"] = AnthropicTab(id: tabID, name: "Worker", isManaged: true)
        transcript = FileManager.default.temporaryDirectory
            .appendingPathComponent("endpoint-\(UUID().uuidString).jsonl")
        try Data().write(to: transcript)
        backend.paths[tabID] = transcript.path
    }

    // MARK: helpers

    /// `tab` becomes the ADMIRAL_TAB_NAME header (nil omits it). Headers arrive from
    /// `HTTPWire.parse` with lowercased keys, so that's what the fake sends.
    private func post(_ body: String, path: String = "/v1/messages", method: String = "POST",
                       tab: String? = "Worker", apiKey: String? = AnthropicEndpointTests.apiToken,
                       headers: [String: String] = [:]) async -> (status: Int, json: [String: Any]) {
        var headers = headers
        if let tab { headers["admiral_tab_name"] = tab }
        if let apiKey { headers["x-api-key"] = apiKey }
        let request = HTTPRequest(method: method, path: path, headers: headers, body: Data(body.utf8))
        var collected = Data()
        await endpoint.handle(request) { collected.append($0) }
        let text = String(data: collected, encoding: .utf8)!
        let status = Int(text.split(separator: " ")[1])!
        let bodyStart = text.range(of: "\r\n\r\n")!.upperBound
        let obj = (try? JSONSerialization.jsonObject(with: Data(text[bodyStart...].utf8))) as? [String: Any] ?? [:]
        return (status, obj)
    }
    /// A real model id, never a tab name — routing must come from the header alone.
    private func requestBody(_ texts: [String], stream: Bool = false) -> String {
        let msgs = texts.map { "{\"role\":\"user\",\"content\":\"\($0)\"}" }.joined(separator: ",")
        return "{\"model\":\"claude-opus-4-8\",\"stream\":\(stream),\"messages\":[\(msgs)]}"
    }
    private func appendTranscript(_ line: String) {
        let handle = try! FileHandle(forWritingTo: transcript)
        handle.seekToEndOfFile(); handle.write(Data((line + "\n").utf8)); try! handle.close()
    }
    private func assistantLine(_ text: String, usage: (Int, Int)) -> String {
        "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"\(text)\"}],\"usage\":{\"input_tokens\":\(usage.0),\"output_tokens\":\(usage.1)}}}"
    }
    private func errorType(_ json: [String: Any]) -> String? {
        (json["error"] as? [String: Any])?["type"] as? String
    }
    /// Real claude echoes the submitted prompt into the transcript as a user line —
    /// simulate that so delivery verification sees the prompt land on the first inject.
    private func echoUserOnInject() {
        backend.onInject = { [self] n in
            if n == 1 { appendTranscript("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"echoed\"}}") }
        }
    }

    // MARK: routing / validation

    func testUnknownPathIs404() async {
        let r = await post("{}", path: "/v1/complete")
        XCTAssertEqual(r.status, 404); XCTAssertEqual(errorType(r.json), "not_found_error")
    }
    func testMalformedBodyIs400() async {
        let r = await post("not json")
        XCTAssertEqual(r.status, 400); XCTAssertEqual(errorType(r.json), "invalid_request_error")
    }
    func testUnknownTabIs404() async {
        let r = await post(requestBody(["x"]), tab: "ghost")
        XCTAssertEqual(r.status, 404); XCTAssertEqual(errorType(r.json), "not_found_error")
    }
    func testBashTabIs400() async {
        backend.tabs["shell"] = AnthropicTab(id: UUID(), name: "shell", isManaged: false)
        let r = await post(requestBody(["x"]), tab: "shell")
        XCTAssertEqual(r.status, 400)
    }
    func testNoNewUserMessageIs400() async {
        appendTranscript("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"already sent\"}}")
        let r = await post(requestBody(["already sent"]))
        XCTAssertEqual(r.status, 400)
        XCTAssertTrue(backend.injected.isEmpty)
    }

    // MARK: ADMIRAL_TAB_NAME header

    func testMissingBothRoutingHeadersIs400() async {
        let r = await post(requestBody(["q"]), tab: nil)
        XCTAssertEqual(r.status, 400)
        XCTAssertEqual(errorType(r.json), "invalid_request_error")
        XCTAssertEqual((r.json["error"] as? [String: Any])?["message"] as? String,
                       "exactly one of ADMIRAL_SESSION_ID or ADMIRAL_TAB_NAME is required")
        XCTAssertTrue(backend.injected.isEmpty)
    }

    func testBlankTabHeaderIs400() async {
        let r = await post(requestBody(["q"]), tab: "   ")
        XCTAssertEqual(r.status, 400)
        XCTAssertEqual(errorType(r.json), "invalid_request_error")
        XCTAssertTrue(backend.injected.isEmpty)
    }

    /// The model field names a real model, never a tab — and a tab named in `model`
    /// is not a fallback when the header points at nothing.
    func testModelFieldIsNotATabFallback() async {
        let body = "{\"model\":\"Worker\",\"messages\":[{\"role\":\"user\",\"content\":\"q\"}]}"
        let r = await post(body, tab: "ghost")
        XCTAssertEqual(r.status, 404)
        XCTAssertTrue(backend.injected.isEmpty)
    }

    /// End-to-end through the wire parser: the header goes out uppercase, and
    /// `HTTPWire.parse` lowercases keys — so the endpoint's lookup key must match
    /// what the parser produces, not what the client typed.
    func testHeaderArrivesFromTheWireRegardlessOfCase() async {
        echoUserOnInject()
        backend.onPoll = { [self] n in
            if n == 2 { appendTranscript(assistantLine("ok", usage: (1, 1))) }
        }
        let body = requestBody(["q"])
        let raw = "POST /v1/messages HTTP/1.1\r\nHost: 127.0.0.1:4141\r\nADMIRAL_TAB_NAME: Worker\r\n"
            + "X-Api-Key: \(Self.apiToken)\r\n"
            + "Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let request = HTTPWire.parse(Data(raw.utf8))
        XCTAssertNotNil(request)
        var collected = Data()
        await endpoint.handle(request!) { collected.append($0) }
        let text = String(data: collected, encoding: .utf8)!
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK"), text.prefix(40).description)
        XCTAssertEqual(backend.injected.count, 1)
    }
    // MARK: operator token

    /// No API token is required: a missing, empty, or wrong key still runs the turn.
    func testRequestSucceedsWithNoOrWrongToken() async {
        for key in [nil, "", "adm_wrong"] as [String?] {
            let backend = FakeAnthropicBackend()
            let endpoint = AnthropicEndpoint(backend: backend, config: Self.cfg)
            let tabID = UUID()
            backend.tabs["Worker"] = AnthropicTab(id: tabID, name: "Worker", isManaged: true)
            let transcript = FileManager.default.temporaryDirectory
                .appendingPathComponent("endpoint-notoken-\(UUID().uuidString).jsonl")
            try! Data().write(to: transcript)
            backend.paths[tabID] = transcript.path
            backend.onInject = { n in
                guard n == 1 else { return }
                let handle = try! FileHandle(forWritingTo: transcript)
                handle.seekToEndOfFile()
                handle.write(Data("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"echoed\"}}\n".utf8))
                try! handle.close()
            }
            backend.onPoll = { n in
                guard n == 2 else { return }
                let line = "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"ok\"}],\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n"
                let handle = try! FileHandle(forWritingTo: transcript)
                handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try! handle.close()
            }
            var headers = ["admiral_tab_name": "Worker"]
            if let key { headers["x-api-key"] = key }
            let request = HTTPRequest(method: "POST", path: "/v1/messages", headers: headers,
                                      body: Data(requestBody(["q"]).utf8))
            var collected = Data()
            await endpoint.handle(request) { collected.append($0) }
            let text = String(data: collected, encoding: .utf8)!
            XCTAssertTrue(text.hasPrefix("HTTP/1.1 200"), "\(key ?? "nil"): \(text.prefix(120))")
            XCTAssertEqual(backend.injected.count, 1, key ?? "nil")
        }
    }

    /// A session-id route also runs with no token, and it does create the scratch tab.
    func testSessionRouteSucceedsWithoutAToken() async {
        let backend = FakeAnthropicBackend()
        let endpoint = AnthropicEndpoint(backend: backend, config: Self.cfg)
        let transcript = FileManager.default.temporaryDirectory
            .appendingPathComponent("endpoint-nosid-\(UUID().uuidString).jsonl")
        try! Data().write(to: transcript)
        backend.createResult = { _, _, _, _ in
            let tab = AnthropicTab(id: UUID(), name: "scratch", isManaged: true)
            backend.paths[tab.id] = transcript.path
            return tab
        }
        backend.statuses = [.busy, .idle]
        backend.onInject = { n in
            guard n == 1 else { return }
            let handle = try! FileHandle(forWritingTo: transcript)
            handle.seekToEndOfFile()
            handle.write(Data("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"echoed\"}}\n".utf8))
            try! handle.close()
        }
        backend.onPoll = { n in
            guard n == 1 else { return }
            let line = "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"ok\"}],\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n"
            let handle = try! FileHandle(forWritingTo: transcript)
            handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try! handle.close()
        }
        let request = HTTPRequest(
            method: "POST", path: "/v1/messages",
            headers: [
                "admiral_session_id": UUID().uuidString,
                "admiral_cwd": FileManager.default.temporaryDirectory.path,
            ],
            body: Data(requestBody(["q"]).utf8))
        var collected = Data()
        await endpoint.handle(request) { collected.append($0) }
        let text = String(data: collected, encoding: .utf8)!
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200"), String(text.prefix(120)))
        XCTAssertEqual(backend.created.count, 1)
        XCTAssertEqual(backend.injected.count, 1)
    }

    /// A Bearer header is ignored, not required: the turn still runs.
    func testBearerTokenIsAccepted() async {
        echoUserOnInject()
        backend.onPoll = { [self] n in
            if n == 2 { appendTranscript(assistantLine("ok", usage: (1, 1))) }
        }
        let r = await post(requestBody(["q"]), apiKey: nil,
                           headers: ["authorization": "Bearer \(Self.apiToken)"])
        XCTAssertEqual(r.status, 200)
    }

    // MARK: origin / host guard

    func testOriginHeaderIsRefused403() async {
        let r = await post(requestBody(["q"]), headers: ["origin": "https://evil.example"])
        XCTAssertEqual(r.status, 403)
        XCTAssertEqual(errorType(r.json), "permission_error")
        XCTAssertTrue(backend.injected.isEmpty)
    }

    func testNonLoopbackHostIsRefused403() async {
        let r = await post(requestBody(["q"]), headers: ["host": "evil.example.com"])
        XCTAssertEqual(r.status, 403)
        XCTAssertEqual(errorType(r.json), "permission_error")
        XCTAssertTrue(backend.injected.isEmpty)
    }

    func testLoopbackHostAllowed() async {
        backend.onPoll = { [self] n in
            if n == 2 { appendTranscript(assistantLine("ok", usage: (1, 1))) }
        }
        let r = await post(requestBody(["q"]), headers: ["host": "127.0.0.1:4141"])
        XCTAssertNotEqual(r.status, 403)
        XCTAssertEqual(r.status, 200)
    }

    // MARK: busy gate & concurrency

    func testBusyBeyondGateIs529() async {
        backend.statuses = [.busy] // stays busy forever
        let r = await post(requestBody(["q"]))
        XCTAssertEqual(r.status, 529); XCTAssertEqual(errorType(r.json), "overloaded_error")
        XCTAssertTrue(backend.injected.isEmpty)
    }

    func testConcurrentRequestSameTabIs529() async {
        backend.statuses = [.idle]
        backend.onPoll = { [self] n in
            if n == 2 { appendTranscript(assistantLine("done", usage: (1, 1))) }
        }
        // Complete one request to prove in-flight clears, then race two.
        backend.statuses = [.idle, .busy, .idle]
        async let first = post(requestBody(["q1"]))
        try? await Task.sleep(nanoseconds: 5_000_000) // let the first claim the tab
        let second = await post(requestBody(["q2"]))
        XCTAssertEqual(second.status, 529)
        _ = await first
    }

    // MARK: the happy path

    func testHappyPathInjectsDeltaAndReturnsCapturedText() async {
        appendTranscript("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"old q\"}}")
        // gate poll: idle → after inject: busy, busy, idle
        backend.statuses = [.idle, .busy, .busy, .idle]
        echoUserOnInject()
        backend.onPoll = { [self] n in
            if n == 3 { appendTranscript(assistantLine("the answer", usage: (42, 7))) }
        }
        let r = await post(requestBody(["old q", "new q"]))
        XCTAssertEqual(r.status, 200)
        // only the unseen message injected
        XCTAssertEqual(backend.injected.count, 1)
        XCTAssertEqual(backend.injected[0].text, "new q")
        XCTAssertEqual(r.json["model"] as? String, "claude-opus-4-8")   // echoed, not the tab
        XCTAssertEqual((r.json["content"] as? [[String: Any]])?.first?["text"] as? String, "the answer")
        XCTAssertEqual((r.json["usage"] as? [String: Any])?["input_tokens"] as? Int, 42)
        XCTAssertEqual(r.json["stop_reason"] as? String, "end_turn")
    }

    func testMultipleUnseenMessagesInjectJoined() async {
        backend.statuses = [.idle, .busy, .idle]
        echoUserOnInject()
        backend.onPoll = { [self] n in
            if n == 2 { appendTranscript(assistantLine("ok", usage: (1, 1))) }
        }
        _ = await post(requestBody(["first", "second"]))
        XCTAssertEqual(backend.injected.count, 1)
        XCTAssertEqual(backend.injected[0].text, "first\n\nsecond")
    }

    func testNoBusyFallbackCompletesWhenTextAppeared() async {
        // status never goes busy (fast hook miss) but output lands and status reads idle
        backend.statuses = [.idle]
        backend.onPoll = { [self] n in
            if n == 2 { appendTranscript(assistantLine("quick", usage: (1, 2))) }
        }
        let r = await post(requestBody(["q"]))
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual((r.json["content"] as? [[String: Any]])?.first?["text"] as? String, "quick")
    }

    func testTurnTimeoutReturnsWhatWasCaptured() async {
        backend.statuses = [.idle, .busy] // busy forever after inject
        backend.onPoll = { [self] n in
            if n == 3 { appendTranscript(assistantLine("partial", usage: (1, 1))) }
        }
        let r = await post(requestBody(["q"]))
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual((r.json["content"] as? [[String: Any]])?.first?["text"] as? String, "partial")
    }

    func testOffsetAdvancesAcrossPollsForTailRead() async {
        // Two assistant lines land on two separate polls; the tail-read must
        // capture both (proving the absolute offset bookkeeping survives a
        // per-poll FileHandle-based tail read instead of a whole-file read). Six polls can outlast
        // the class's 0.2s cap on a slow CI runner, so this test — about offsets, not timing —
        // gets a wide one; the busy→idle edge at poll 6 still ends it at once.
        var cfg = Self.cfg
        cfg.turnTimeout = 5
        endpoint = AnthropicEndpoint(backend: backend, config: cfg)
        backend.statuses = [.idle, .busy, .busy, .busy, .busy, .idle]
        backend.onPoll = { [self] n in
            if n == 3 { appendTranscript(assistantLine("first", usage: (1, 1))) }
            if n == 5 { appendTranscript(assistantLine("second", usage: (2, 2))) }
        }
        let r = await post(requestBody(["q"]))
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual((r.json["content"] as? [[String: Any]])?.first?["text"] as? String, "first\n\nsecond")
        XCTAssertEqual((r.json["usage"] as? [String: Any])?["input_tokens"] as? Int, 2)
    }

    func testMissingTranscriptIs500() async {
        backend.paths[tabID] = nil
        let r = await post(requestBody(["q"]))
        XCTAssertEqual(r.status, 500); XCTAssertEqual(errorType(r.json), "api_error")
    }

    func testFreshTabWithNoTranscriptFileBootstraps() async {
        // A brand-new managed tab: the path is KNOWN (deterministic) but the file does
        // not exist yet. The endpoint must treat the missing file as empty history,
        // inject the first message (which is what makes claude create the transcript),
        // then capture the reply — NOT 500.
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("fresh-\(UUID().uuidString).jsonl")
        backend.paths[tabID] = missing.path   // path known, file absent
        backend.statuses = [.idle, .busy, .idle]
        // claude CREATES the transcript when the injected turn lands: user line first…
        backend.onInject = { n in
            guard n == 1 else { return }
            try? Data("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"first message\"}}\n".utf8)
                .write(to: missing)
        }
        // …then the reply, mid-turn.
        backend.onPoll = { [self] n in
            if n == 3, let handle = try? FileHandle(forWritingTo: missing) {
                handle.seekToEndOfFile()
                handle.write(Data((assistantLine("bootstrapped", usage: (1, 3)) + "\n").utf8))
                try? handle.close()
            }
        }
        let r = await post(requestBody(["first message"]))
        XCTAssertEqual(r.status, 200)   // not 500 — missing file = empty history
        XCTAssertEqual(backend.injected.count, 1)
        XCTAssertEqual(backend.injected[0].text, "first message")
        XCTAssertEqual((r.json["content"] as? [[String: Any]])?.first?["text"] as? String, "bootstrapped")
    }

    // MARK: session-id routing

    private var sid: String { "0b8f4a2e-1111-2222-3333-444455556666" }

    /// A request routed by session id (no tab header); cwd defaults to a real directory.
    private func postSID(_ body: String, sid: String? = nil, cwd: String? = NSTemporaryDirectory())
    async -> (status: Int, json: [String: Any]) {
        var headers: [String: String] = [:]
        if let sid { headers["admiral_session_id"] = sid }
        if let cwd { headers["admiral_cwd"] = cwd }
        return await post(body, tab: nil, headers: headers)
    }

    func testBothRoutingHeadersIs400() async {
        let r = await post(requestBody(["q"]), tab: "Worker", headers: ["admiral_session_id": sid])
        XCTAssertEqual(r.status, 400)
        XCTAssertTrue(backend.created.isEmpty)
    }

    func testMalformedSessionIDIs400() async {
        let r = await postSID(requestBody(["q"]), sid: "not-a-uuid")
        XCTAssertEqual(r.status, 400)
        XCTAssertEqual(errorType(r.json), "invalid_request_error")
    }

    func testSIDRequestWithoutCwdIs400EvenWhenSIDMatches() async {
        // Presence of ADMIRAL_CWD is required on every sid request, even though a live
        // sid match ignores its value.
        backend.tabsBySession[sid] = backend.tabs["Worker"]!
        let r = await postSID(requestBody(["via sid"]), sid: sid, cwd: nil)
        XCTAssertEqual(r.status, 400, "sid requests still require ADMIRAL_CWD present")
        XCTAssertTrue(backend.injected.isEmpty)
    }

    func testSIDMatchWithCwdHeaderRoutes() async {
        backend.tabsBySession[sid] = backend.tabs["Worker"]!
        backend.statuses = [.busy, .idle]
        backend.onPoll = { [self] n in if n == 1 { appendTranscript(assistantLine("done", usage: (1, 2))) } }
        let r = await postSID(requestBody(["via sid"]), sid: sid)
        XCTAssertEqual(r.status, 200)
        XCTAssertTrue(backend.created.isEmpty, "existing sid must not create a tab")
        XCTAssertEqual(backend.injected.first?.text, "via sid")
    }

    func testUnknownSIDCreatesScratchTab() async {
        backend.createResult = { [self] _, _, _, _ in
            let tab = AnthropicTab(id: UUID(), name: "temp", isManaged: true)
            backend.tabsBySession[sid] = tab
            backend.paths[tab.id] = transcript.path   // reuse the test transcript
            return tab
        }
        backend.statuses = [.busy, .idle]
        backend.onPoll = { [self] n in if n == 1 { appendTranscript(assistantLine("hi", usage: (1, 1))) } }
        let r = await postSID(requestBody(["first"]), sid: sid)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(backend.created.count, 1)
        XCTAssertEqual(backend.created.first?.sid, sid)
    }

    func testUnknownSIDWithMissingCwdIs400() async {
        let r = await postSID(requestBody(["q"]), sid: sid, cwd: nil)
        XCTAssertEqual(r.status, 400)
        XCTAssertTrue(backend.created.isEmpty)
    }

    func testUnknownSIDWithBogusCwdIs400() async {
        let r = await postSID(requestBody(["q"]), sid: sid, cwd: "/definitely/not/here-\(UUID())")
        XCTAssertEqual(r.status, 400)
        XCTAssertTrue(backend.created.isEmpty)
    }

    func testCreationFailureIs500() async {
        backend.createResult = { _, _, _, _ in nil }
        let r = await postSID(requestBody(["q"]), sid: sid)
        XCTAssertEqual(r.status, 500)
        XCTAssertEqual(errorType(r.json), "api_error")
    }

    // MARK: verified prompt delivery (freshly created tabs lose early keystrokes)

    private func userLine(_ text: String) -> String {
        "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"\(text)\"}}"
    }

    /// Cold tab: the first inject is lost (claude's TUI isn't reading stdin yet); the
    /// endpoint must notice the transcript never gained the user line and re-inject.
    func testColdTabRetriesInjectUntilPromptLands() async {
        backend.statuses = [.unknown, .unknown, .idle]
        backend.onInject = { [self] n in
            guard n == 2 else { return }   // first attempt evaporates; second lands
            appendTranscript(userLine("hello"))
            appendTranscript(assistantLine("hi there", usage: (1, 2)))
        }
        let r = await post(requestBody(["hello"]))
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(backend.injected.count, 2, "must re-inject after the lost first attempt")
    }

    /// Warm tab: the prompt lands on the first attempt — exactly one inject, never a
    /// duplicate send.
    func testWarmTabInjectsExactlyOnce() async {
        backend.statuses = [.busy, .idle]
        backend.onInject = { [self] n in
            guard n == 1 else { return }
            appendTranscript(userLine("q"))
            appendTranscript(assistantLine("a", usage: (1, 1)))
        }
        let r = await post(requestBody(["q"]))
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(backend.injected.count, 1, "a delivered prompt must not be re-sent")
    }

    /// The prompt never lands (wedged tab): give up after injectMaxAttempts and fall
    /// through to the normal turn timeout — today's behavior, plus the retries.
    func testUndeliveredPromptStopsRetryingAfterMaxAttempts() async {
        let r = await post(requestBody(["void"]))
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(backend.injected.count, 3, "retries are bounded by injectMaxAttempts")
    }

    /// A tab whose claude never writes a session file (status stays unknown) still gets
    /// inject attempts once injectReadyTimeout expires — readiness is a wait, not a gate.
    func testUnknownStatusForeverStillAttemptsInject() async {
        backend.statuses = [.unknown]
        let r = await post(requestBody(["boot?"]))
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(backend.injected.count, 3)
    }
}
