import XCTest
@testable import AdmiralCore

extension AcpAgentConfig {
    static var sample: AcpAgentConfig {
        AcpAgentConfig(
            name: "claude-box",
            launch: AcpCommand(command: "docker", args: ["exec", "-i", "box", "claude-agent-acp"]),
            cwd: "/workspace")
    }
}

final class AcpAgentConfigTests: XCTestCase {
    func testDerivedExecKeepsContainerAndFlagsDropsInteractiveAndAgentBinary() {
        let launch = AcpCommand(command: "docker", args: ["exec", "-i", "-w", "/workspace", "-e", "HOME=/home/node",
            "ppt-claude-1", "npx", "-y", "@agentclientprotocol/claude-agent-acp", "--dangerously-skip-permissions"])
        XCTAssertEqual(AcpAgentConfig.derivedExec(from: launch),
            AcpCommand(command: "docker", args: ["exec", "-w", "/workspace", "-e", "HOME=/home/node", "ppt-claude-1"]))
    }

    func testDerivedExecHandlesUserFlagAndCombinedIT() {
        let launch = AcpCommand(command: "docker", args: ["exec", "-it", "-u", "node", "box", "claude-agent-acp"])
        XCTAssertEqual(
            AcpAgentConfig.derivedExec(from: launch),
            AcpCommand(command: "docker", args: ["exec", "-u", "node", "box"]))
    }

    func testNonDockerLaunchHasNoDerivedExec() {
        XCTAssertNil(AcpAgentConfig.derivedExec(from: AcpCommand(command: "ssh", args: ["host", "claude-agent-acp"])))
        XCTAssertNil(AcpAgentConfig.derivedExec(from: AcpCommand(command: "docker", args: ["run", "-i", "img"])))
    }

    func testExplicitExecWinsOverDerived() {
        var c = AcpAgentConfig.sample
        XCTAssertEqual(c.effectiveExec, AcpCommand(command: "docker", args: ["exec", "box"]))
        let explicit = AcpCommand(command: "docker", args: ["exec", "-u", "root", "other"])
        c.exec = explicit
        XCTAssertEqual(c.effectiveExec, explicit)
    }

    func testValidationRequiresNameCommandAndAbsoluteCwd() {
        var c = AcpAgentConfig.sample
        XCTAssertEqual(c.validationErrors, [])
        c.cwd = "workspace"
        XCTAssertEqual(c.validationErrors, ["cwd must be an absolute path as the agent sees it"])
        c.name = "  "
        c.launch.command = ""
        XCTAssertEqual(c.validationErrors.count, 3)
    }

    func testDetectsIgnoredSkipPermissionsFlag() {
        var c = AcpAgentConfig.sample
        XCTAssertFalse(c.passesIgnoredSkipPermissionsFlag)
        c.launch.args.append("--dangerously-skip-permissions")
        XCTAssertTrue(c.passesIgnoredSkipPermissionsFlag)
    }

    func testStoreRoundTripsAndFindsByName() {
        let suite = "AcpAgentConfigTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AcpAgentStore(defaults: defaults)
        XCTAssertEqual(store.load(), [])
        var second = AcpAgentConfig.sample
        second.id = UUID()
        second.name = "Other"
        let saved = [AcpAgentConfig.sample, second]
        store.save(saved)
        XCTAssertEqual(store.load(), saved)
        XCTAssertEqual(store.agent(named: "OTHER")?.id, second.id)
        XCTAssertNil(store.agent(named: "missing"))
    }

    func testDefaults() {
        let c = AcpAgentConfig(name: "a", launch: AcpCommand(command: "x", args: []), cwd: "/w")
        XCTAssertEqual(c.defaultMode, "bypassPermissions")
        XCTAssertEqual(c.mcpCallbackURL, "http://host.docker.internal:4142")
        XCTAssertNil(c.exec)
        XCTAssertTrue(c.env.isEmpty)
        XCTAssertTrue(c.defaultConfigOptions.isEmpty)
    }
}
