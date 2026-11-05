import XCTest
@testable import AdmiralCore

final class SessionBridgePolicyTests: XCTestCase {
    private let ppt = AcpAgentConfig(name: "PPT", launch: AcpCommand(command: "agent"), cwd: "/w")
    private let other = AcpAgentConfig(name: "Other", launch: AcpCommand(command: "agent"), cwd: "/o")
    private let t0 = Date(timeIntervalSinceReferenceDate: 1000)

    func testFollowsTheAgentList() {
        let policy = SessionBridgePolicy()
        XCTAssertEqual(policy.action(agents: [ppt], running: false, now: t0), .start)
        XCTAssertEqual(policy.action(agents: [ppt], running: true, now: t0), .none)
        XCTAssertEqual(policy.action(agents: [], running: true, now: t0), .stop)
        XCTAssertEqual(policy.action(agents: [], running: false, now: t0), .none)
    }

    /// A defaults write that leaves the agents as they were does not retry a failed bind.
    func testNoRetryOnUnrelatedDefaultsChange() {
        var policy = SessionBridgePolicy()
        policy.startFailed(agents: [ppt], now: t0)
        XCTAssertEqual(policy.action(agents: [ppt], running: false, now: t0.addingTimeInterval(1)), .none)
        XCTAssertEqual(policy.action(agents: [ppt], running: false, now: t0.addingTimeInterval(59)), .none)
    }

    func testRetriesWhenTheAgentsChangeOrTheIntervalPasses() {
        var policy = SessionBridgePolicy()
        policy.startFailed(agents: [ppt], now: t0)
        XCTAssertEqual(policy.action(agents: [ppt, other], running: false, now: t0.addingTimeInterval(1)), .start)
        XCTAssertEqual(policy.action(agents: [ppt], running: false,
                                     now: t0.addingTimeInterval(SessionBridgePolicy.retryInterval)), .start)
        policy.reset()
        XCTAssertEqual(policy.action(agents: [ppt], running: false, now: t0.addingTimeInterval(1)), .start)
    }
}
