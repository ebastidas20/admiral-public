import XCTest
@testable import AdmiralCore

/// The per-session driver every tab's input goes through. Only the PTY driver exists today;
/// these pin what it sends so a second driver can't drift the PTY path.
@MainActor
final class SessionDriverTests: XCTestCase {
    private var host: FakeTerminalHost!
    private var base: URL!
    private var manager: SessionManager!

    override func setUp() async throws {
        try await super.setUp()
        host = FakeTerminalHost()
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("driver-\(UUID().uuidString)")
        manager = SessionManager(host: host, claudeHome: base, executablePath: "/bin/echo",
                                 supportDir: base)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: base) }

    private func tab() -> AgentSession {
        let s = AgentSession(callsign: "a", cwd: "/tmp", claudeSessionID: "sid-a", status: .idle)
        manager.register(s, handle: host.spawn(executable: "/bin/echo", args: [], env: [:],
                                               cwd: "/tmp", onExit: { _ in }))
        return s
    }

    private let questions = [
        AskQuestion(question: "Which DB?", header: "DB",
                    options: [AskOption(label: "Postgres", description: "")]),
        AskQuestion(question: "Tests?", header: "Tests", options: []),
    ]

    func testPTYDriverSubmitsThroughHost() {
        let handle = host.spawn(executable: "/bin/echo", args: [], env: [:], cwd: "/tmp", onExit: { _ in })
        let driver = PTYSessionDriver(
            host: host, handle: handle, claudeHome: base, session: { nil },
            sendPeerMessage: { _, _, _ in XCTFail("no socket without a session") })
        let prompt = TerminalPrompt.injected("hello")
        XCTAssertTrue(driver.submit(prompt: prompt))
        XCTAssertEqual(host.prompts, [prompt])
        XCTAssertEqual(host.sent, ["hello", "\r"])
        XCTAssertEqual(driver.pid, handle.pid)
        XCTAssertTrue(driver.handle === handle)
    }

    func testAnswerAskTypesAnswerTextForPTY() {
        let s = tab()
        manager.answerAsk(s.id, questions: questions, answers: ["Postgres", ""])
        let expected = SessionManager.typedText(AskAnswer.text(questions: questions, answers: ["Postgres", ""]))
        XCTAssertEqual(host.sent, [expected, "\r"])
        XCTAssertNotNil(manager.sessions.first { $0.id == s.id }?.lastActivityAt)
    }

    func testAllowPermissionSendsEnterForPTY() {
        let s = tab()
        manager.allowPermission(s.id)
        XCTAssertEqual(host.sent, ["\r"])
    }

    func testAgentSessionDefaultsToPTYBackend() {
        let s = AgentSession(callsign: "a", cwd: "/tmp")
        XCTAssertEqual(s.backend, .pty)
        XCTAssertNil(s.acpSessionID)
        var acp = s
        acp.backend = .acp(agentName: "Gemini")
        XCTAssertNotEqual(acp, s)
    }

    func testDeleteTerminatesThroughTheDriver() {
        let s = tab()
        manager.delete(s.id)
        XCTAssertEqual(host.terminatedPIDs, [4242])
        XCTAssertNil(manager.handle(for: s.id))
    }
}
