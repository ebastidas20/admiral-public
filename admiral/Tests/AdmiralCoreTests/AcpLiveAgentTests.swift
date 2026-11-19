import XCTest
@testable import AdmiralCore

/// An ACP tab against a REAL agent, over either transport. Opt-in: skips unless one is named.
///
/// ```
/// # WebSocket: an agent already serving ACP (e.g. the Sailor harness's /acp)
/// ADMIRAL_ACP_WS_URL=ws://127.0.0.1:8740/acp ADMIRAL_ACP_WS_META='{"agent":"<name>"}' \
///   swift test --filter AcpLiveAgentTests
/// # stdio: an agent Admiral launches on this Mac
/// ADMIRAL_ACP_STDIO_ARGV='["npx","-y","<agent-package>@<version>"]' swift test --filter AcpLiveAgentTests
/// ```
///
/// Drives the real paths — the default `acpTransportFactory` (`WebSocketAcpTransport` or
/// `ProcessAcpTransport`), `testACPConnection`, `commissionACP`, a typed prompt, a hail — with a
/// temp support dir and an isolated `UserDefaults` suite. `ADMIRAL_ACP_WS_PROMPT` overrides the
/// prompt; `ADMIRAL_ACP_WS_EXPECT` is text the reply must contain (default: any reply).
@MainActor
final class AcpLiveAgentTests: XCTestCase {
    private static let env = ProcessInfo.processInfo.environment
    private var base: URL!
    private var suite: String!
    private var manager: SessionManager!

    override func setUp() async throws {
        try await super.setUp()
        guard Self.env["ADMIRAL_ACP_WS_URL"]?.isEmpty == false || Self.stdioArgv != nil else {
            throw XCTSkip("live ACP tests run only with ADMIRAL_ACP_WS_URL=ws://… or "
                + "ADMIRAL_ACP_STDIO_ARGV='[\"npx\",\"-y\",\"<agent>@<version>\"]'")
        }
        base = FileManager.default.temporaryDirectory.appendingPathComponent("acp-ws-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        suite = "acp-ws-e2e-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        manager = SessionManager(
            host: FakeTerminalHost(), claudeHome: base, executablePath: "/bin/echo",
            appearanceStore: SessionAppearanceStore(defaults: defaults),
            openSessionsStore: OpenSessionsStore(defaults: defaults), supportDir: base,
            touchedReposStore: TouchedReposStore(defaults: defaults))
        let a = agent()
        manager.acpAgents = { [a] }
        manager.sessionBridgeRunning = { false }
    }

    override func tearDown() async throws {
        manager?.terminateAll()
        if let suite { UserDefaults().removePersistentDomain(forName: suite) }
        if let base { try? FileManager.default.removeItem(at: base) }
        try await super.tearDown()
    }

    /// `ADMIRAL_ACP_STDIO_ARGV`: a JSON array, the stdio agent's command then args. When set
    /// (and no WebSocket URL is), the same tests run over `ProcessAcpTransport` on this Mac.
    private static var stdioArgv: [String]? {
        guard let text = env["ADMIRAL_ACP_STDIO_ARGV"], let data = text.data(using: .utf8),
              let argv = try? JSONDecoder().decode([String].self, from: data), !argv.isEmpty else { return nil }
        return argv
    }

    private func agent() -> AcpAgentConfig {
        let meta = AcpAgentDraft.parseMeta(Self.env["ADMIRAL_ACP_WS_META"] ?? "")
        if Self.env["ADMIRAL_ACP_WS_URL"]?.isEmpty != false, let argv = Self.stdioArgv {
            return AcpAgentConfig(
                name: "stdio-agent", transport: .stdio,
                launch: AcpCommand(command: argv[0], args: Array(argv.dropFirst())),
                sessionMeta: (try? meta.get()) ?? [:], cwd: base.path)
        }
        return AcpAgentConfig(
            name: "ws-agent", transport: .webSocket, launch: AcpCommand(command: ""),
            url: Self.env["ADMIRAL_ACP_WS_URL"] ?? "", sessionMeta: (try? meta.get()) ?? [:],
            cwd: "/", workspace: .elsewhere(exec: nil), mcpCallbackURL: "http://127.0.0.1:4142")
    }

    private func until(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return true
    }

    private func log(_ s: AgentSession) -> String {
        (try? String(contentsOf: SessionManager.acpLogURL(base: base, session: s.claudeSessionID!), encoding: .utf8)) ?? ""
    }

    func testConnectionOverWebSocket() async throws {
        let result = await manager.testACPConnection(agent())
        guard case let .connected(r) = result else { return XCTFail("\(result)") }
        print("WS E2E: agent=\(r.negotiated.agentName ?? "nil") loadSession=\(r.negotiated.loadSession)")
        XCTAssertNotNil(r.negotiated.agentName)
    }

    /// A hail from a claude tab reaches the WebSocket agent's tab as its next prompt, and the
    /// agent's reply lands in the mirror.
    func testHailReachesWebSocketTab() async throws {
        let tab = manager.commissionACP(agent: agent(), callsign: "ws-hailed")
        let opened = await until(60) { self.manager.sessions.first { $0.id == tab.id }?.status == .idle }
        let s = manager.sessions.first { $0.id == tab.id }!
        guard opened else { return XCTFail("no idle; error=\(s.connectError ?? "nil")\n\(log(s))") }
        manager.register(AgentSession(callsign: "sender", cwd: "/tmp", token: "SENDER"),
                         handle: FakeTerminalHost.Handle(pid: 1))
        let bridge = BridgeCore(manager: manager, goalsStore: GoalsStore(base: base))
        let result = bridge.hail(fromToken: "SENDER", to: "ws-hailed", body: "hello from a hail")
        print("WS E2E: hail -> ok=\(result.ok) \(result.message)")
        XCTAssertTrue(result.ok, result.message)
        let mirror = TranscriptMirror.url(base: base, session: s.claudeSessionID!)
        let expect = Self.env["ADMIRAL_ACP_WS_EXPECT"] ?? ""
        let done = await until(120) {
            let text = (try? String(contentsOf: mirror, encoding: .utf8)) ?? ""
            return text.contains("hello from a hail") && text.contains("\"assistant\"")
                && (expect.isEmpty || text.contains(expect))
                && self.manager.sessions.first { $0.id == tab.id }?.status == .idle
        }
        // Out over the WebSocket as a `session/prompt` carrying the hail.
        let sent = log(s).replacingOccurrences(of: "\\/", with: "/").split(separator: "\n").filter {
            $0.hasPrefix("acp: -> ") && $0.contains("\"session/prompt\"") && $0.contains("hello from a hail")
        }
        XCTAssertEqual(sent.count, 1, "the hail went out as one session/prompt")
        let last = ((try? String(contentsOf: mirror, encoding: .utf8)) ?? "").split(separator: "\n").last ?? ""
        print("WS E2E: hail reply line: \(last.prefix(400))")
        XCTAssertTrue(done, "hail not answered; log:\n\(log(s).suffix(3000))")
    }

    func testTabPromptAndReplyOverWebSocket() async throws {
        let tab = manager.commissionACP(agent: agent(), callsign: "ws-e2e")
        let opened = await until(60) { self.manager.sessions.first { $0.id == tab.id }?.status == .idle }
        let s = manager.sessions.first { $0.id == tab.id }!
        guard opened else {
            return XCTFail("no idle after 60 s; status=\(s.status) error=\(s.connectError ?? "nil")\n\(log(s))")
        }
        XCTAssertNotNil(s.acpSessionID)
        XCTAssertTrue(log(s).contains("\"_meta\"") || agent().sessionMeta.isEmpty, "session/new carried no _meta")

        let prompt = Self.env["ADMIRAL_ACP_WS_PROMPT"] ?? "Reply with exactly: pong"
        XCTAssertTrue(manager.sendTyped(tab.id, text: prompt))
        var sawBusy = false
        let mirror = TranscriptMirror.url(base: base, session: s.claudeSessionID!)
        let expect = Self.env["ADMIRAL_ACP_WS_EXPECT"] ?? ""
        let done = await until(120) {
            let status = self.manager.sessions.first { $0.id == tab.id }?.status
            if status == .busy { sawBusy = true }
            let text = (try? String(contentsOf: mirror, encoding: .utf8)) ?? ""
            return sawBusy && status == .idle && text.contains("\"assistant\"")
                && (expect.isEmpty || text.contains(expect))
        }
        let text = (try? String(contentsOf: mirror, encoding: .utf8)) ?? ""
        print("WS E2E: busy=\(sawBusy) mirror lines=\(text.split(separator: "\n").count)")
        XCTAssertTrue(done, "no reply mirrored; log:\n\(log(s).suffix(3000))")
    }
}
