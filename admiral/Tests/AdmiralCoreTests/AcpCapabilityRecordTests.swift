import XCTest
@testable import AdmiralCore

/// What an ACP tab can do, and the exact words for what it can't — read by the UI (disabled
/// controls) and by the git/PR features (skipped), so the copy is asserted verbatim.
final class AcpCapabilityRecordTests: XCTestCase {
    /// Answers each probe with the exit code it was scripted with; records every argv.
    private final class ProbeRunner: CommandRunner, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [(argv: [String], cwd: String?, timeout: TimeInterval)] = []
        var calls: [(argv: [String], cwd: String?, timeout: TimeInterval)] { lock.withLock { _calls } }
        let codes: [String: Int32?]

        init(_ codes: [String: Int32?]) { self.codes = codes }

        func run(_ argv: [String], cwd: String?, timeout: TimeInterval) -> (code: Int32, stdout: String)? {
            lock.withLock { _calls.append((argv, cwd, timeout)) }
            guard let code = codes[argv.joined(separator: " ")] ?? nil else { return nil }
            return (code, "")
        }
    }

    private func caps(_ agentCapabilities: [String: JSONValue] = [:]) -> AcpCapabilities {
        AcpCapabilities(initializeResult: .object(["agentCapabilities": .object(agentCapabilities)]))
    }

    private let allGitFeatures: [AcpFeature] = [.branch, .touchedRepos, .prWatch]

    func testNoExecDisablesGitFeaturesWithReason() {
        let record = AcpCapabilityRecord(negotiated: caps())
        XCTAssertFalse(record.hasExec)
        for f in allGitFeatures {
            XCTAssertFalse(record.isEnabled(f), "\(f)")
            XCTAssertEqual(record.reason(f), "No exec command configured for this agent", "\(f)")
        }
        XCTAssertEqual(AcpCapabilityRecord.probe(runner: nil, cwd: "/workspace").git, nil)
        XCTAssertEqual(AcpCapabilityRecord.probe(runner: nil, cwd: "/workspace").gh, nil)
        XCTAssertEqual(AcpCapabilityRecord.probe(runner: nil, cwd: "/workspace").ghAuthed, nil)
    }

    func testProbingRecordSaysCheckingNotNoExec() {
        let probing = AcpCapabilityRecord(negotiated: caps(), hasExec: true)
        for f in allGitFeatures {
            XCTAssertFalse(probing.isEnabled(f), "\(f)")
            XCTAssertEqual(probing.reason(f), "Checking the agent's environment\u{2026}", "\(f)")
        }
        XCTAssertEqual(probing.reason(.branch)?.last, "\u{2026}", "the ellipsis is the one Unicode character")

        var landed = probing
        landed.git = true
        landed.gh = true
        landed.ghAuthed = false
        XCTAssertTrue(landed.isEnabled(.branch))
        XCTAssertEqual(landed.reason(.prWatch), "gh is not logged in in the agent's environment")
    }

    func testGitMissingDisablesGitFeaturesWithReason() {
        let record = AcpCapabilityRecord(negotiated: caps(), git: false, gh: true, ghAuthed: true)
        for f in allGitFeatures {
            XCTAssertEqual(record.reason(f), "git not found in the agent's environment", "\(f)")
        }
    }

    func testGhUnauthedDisablesPRWatchOnly() {
        let record = AcpCapabilityRecord(negotiated: caps(), git: true, gh: true, ghAuthed: false)
        XCTAssertTrue(record.isEnabled(.branch))
        XCTAssertNil(record.reason(.branch))
        XCTAssertTrue(record.isEnabled(.touchedRepos))
        XCTAssertFalse(record.isEnabled(.prWatch))
        XCTAssertEqual(record.reason(.prWatch), "gh is not logged in in the agent's environment")

        let noGh = AcpCapabilityRecord(negotiated: caps(), git: true, gh: false, ghAuthed: false)
        XCTAssertTrue(noGh.isEnabled(.branch))
        XCTAssertEqual(noGh.reason(.prWatch), "gh not found in the agent's environment")

        let all = AcpCapabilityRecord(negotiated: caps(), git: true, gh: true, ghAuthed: true)
        XCTAssertTrue(all.isEnabled(.prWatch))
        XCTAssertNil(all.reason(.prWatch))
    }

    func testNegotiatedCapabilitiesGateForkImportSteeringBridge() {
        let none = AcpCapabilityRecord(negotiated: caps())
        XCTAssertEqual(none.reason(.fork), "The agent doesn't support fork")
        XCTAssertEqual(none.reason(.importSessions), "The agent doesn't support session listing")
        XCTAssertEqual(none.reason(.steering), "The agent doesn't support steering")
        XCTAssertEqual(none.reason(.bridgeTools), "The agent doesn't support HTTP MCP")
        for f in [AcpFeature.fork, .importSessions, .steering, .bridgeTools] {
            XCTAssertFalse(none.isEnabled(f), "\(f)")
        }

        let every = AcpCapabilityRecord(negotiated: caps([
            "sessionCapabilities": .object(["fork": .object([:]), "list": .object([:])]),
            "mcpCapabilities": .object(["http": .bool(true)]),
            "_meta": .object(["steering": .object(["supported": .bool(true)])]),
        ]), bridgeRunning: true)
        for f in [AcpFeature.fork, .importSessions, .steering, .bridgeTools] {
            XCTAssertTrue(every.isEnabled(f), "\(f)")
            XCTAssertNil(every.reason(f), "\(f)")
        }
    }

    /// The bridge needs both ends: the agent speaking HTTP MCP, and Admiral's listener up.
    /// An agent without HTTP is named first — starting the listener would not help it.
    func testBridgeToolsNeedTheSessionBridgeRunning() {
        let http = caps(["mcpCapabilities": .object(["http": .bool(true)])])
        let down = AcpCapabilityRecord(negotiated: http, bridgeRunning: false)
        XCTAssertEqual(down.reason(.bridgeTools), "Admiral's session bridge is not running")
        XCTAssertFalse(down.isEnabled(.bridgeTools))
        XCTAssertNil(AcpCapabilityRecord(negotiated: http, bridgeRunning: true).reason(.bridgeTools))
        XCTAssertEqual(AcpCapabilityRecord(negotiated: caps(), bridgeRunning: false).reason(.bridgeTools),
                       "The agent doesn't support HTTP MCP")
    }

    func testProbeParsesExitCodes() {
        let runner = ProbeRunner(["git --version": 0, "gh --version": 0, "gh auth status": 1])
        let probed = AcpCapabilityRecord.probe(runner: runner, cwd: "/workspace")
        XCTAssertEqual(probed.git, true)
        XCTAssertEqual(probed.gh, true)
        XCTAssertEqual(probed.ghAuthed, false)
        XCTAssertEqual(runner.calls.map(\.argv), [["git", "--version"], ["gh", "--version"], ["gh", "auth", "status"]])
        XCTAssertTrue(runner.calls.allSatisfy { $0.cwd == "/workspace" && $0.timeout == 5 })
    }

    func testProbeTreatsUnlaunchableAsMissingAndSkipsAuthWithoutGh() {
        let runner = ProbeRunner(["git --version": nil, "gh --version": 127])
        let probed = AcpCapabilityRecord.probe(runner: runner, cwd: "/w")
        XCTAssertEqual(probed.git, false)
        XCTAssertEqual(probed.gh, false)
        XCTAssertEqual(probed.ghAuthed, false)
        XCTAssertEqual(runner.calls.map(\.argv), [["git", "--version"], ["gh", "--version"]])
    }
}
