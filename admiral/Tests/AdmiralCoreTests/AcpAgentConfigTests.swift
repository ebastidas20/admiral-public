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

    /// R5: a name already used by another agent (any case) is refused; the agent's own saved
    /// entry (same id) is not a duplicate of itself.
    func testDuplicateNameIsRejectedCaseInsensitively() {
        let saved = AcpAgentConfig.sample
        var copy = AcpAgentConfig.sample
        copy.id = UUID()
        copy.name = "  CLAUDE-box "
        XCTAssertEqual(copy.validationErrors(among: [saved]),
                       ["an agent named \u{201C}CLAUDE-box\u{201D} already exists"])
        XCTAssertEqual(saved.validationErrors(among: [saved]), [], "editing an agent keeps its own name")
        copy.name = "claude-box-2"
        XCTAssertEqual(copy.validationErrors(among: [saved]), [])
        copy.name = ""
        XCTAssertEqual(copy.validationErrors(among: [saved]), ["name is required"], "an empty name is not a duplicate")
    }

    /// The connect-error reason is shown in the UI: one huge stderr line is cut, and only the
    /// log's tail is read (an early line beyond it is not reached).
    func testLastAgentLineIsCappedAndReadsOnlyTheTail() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("acp-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("t.log")
        AcpLog.append("early reason", to: log)
        AcpLog.append(String(repeating: "x", count: 20_000), to: log)
        AcpLog.append("acp: admiral's own note", to: log)
        let line = try XCTUnwrap(AcpLog.lastAgentLine(log, after: 0))
        XCTAssertEqual(line.count, AcpLog.maxLineLength)
        XCTAssertTrue(line.hasPrefix("xxx") && line.hasSuffix("\u{2026}"))

        AcpLog.append("short last line", to: log)
        XCTAssertEqual(AcpLog.lastAgentLine(log, after: 0), "short last line")
        let end = AcpLog.size(log)
        XCTAssertNil(AcpLog.lastAgentLine(log, after: end), "nothing after the offset")
    }

    func testDraftRoundTripsAConfig() {
        let config = AcpAgentConfig(
            name: "PPT", launch: AcpCommand(command: "docker", args: ["exec", "-i", "-e", "A=b c", "box", "agent"]),
            env: ["PATH": "/opt/bin:/usr/bin", "TOKEN": "x=y"], cwd: "/workspace", defaultMode: nil,
            defaultConfigOptions: ["model": "opus"], exec: AcpCommand(command: "docker", args: ["exec", "box"]))
        XCTAssertEqual(AcpAgentDraft(config).config, config)
    }

    func testDraftParsesLinesAndPairsAndEmptyExecMeansDerived() {
        var draft = AcpAgentDraft.new()
        XCTAssertEqual(draft.defaultMode, "bypassPermissions")
        XCTAssertEqual(draft.cwd, "/workspace")
        draft.name = " PPT "
        draft.command = "docker"
        draft.args = "exec\n  -i\n\nbox\nnpx -y pkg@1.2.3\n"
        draft.env = "FOO=bar=baz\nnot a pair\n=nokey\n BAR = 1"
        draft.defaultMode = "  "
        let config = draft.config
        XCTAssertEqual(config.name, "PPT")
        XCTAssertEqual(config.launch.args, ["exec", "-i", "box", "npx -y pkg@1.2.3"])
        XCTAssertEqual(config.env, ["FOO": "bar=baz", "BAR": " 1"])
        XCTAssertNil(config.defaultMode, "blank = no mode set")
        XCTAssertNil(config.exec)
        XCTAssertEqual(config.effectiveExec, AcpCommand(command: "docker", args: ["exec", "box"]))
    }

    /// R12: a rename while a tab is open on the old name would orphan that tab (it finds its
    /// agent by name), so it is refused; with no tab on it, or a case-only change, it is fine.
    func testRenameIsRefusedWhileATabUsesTheOldName() {
        let saved = AcpAgentConfig.sample
        var renamed = saved
        renamed.name = "claude-box-2"
        XCTAssertEqual(renamed.validationErrors(among: [saved], openTabAgents: ["CLAUDE-BOX"]),
                       [AcpAgentConfig.renameWithOpenTabs])
        XCTAssertEqual(renamed.validationErrors(among: [saved], openTabAgents: ["other"]), [])
        XCTAssertEqual(renamed.validationErrors(among: [saved]), [])
        var recased = saved
        recased.name = "Claude-Box"
        XCTAssertEqual(recased.validationErrors(among: [saved], openTabAgents: ["claude-box"]), [])
        var unsaved = renamed
        unsaved.id = UUID()
        XCTAssertEqual(unsaved.validationErrors(among: [saved], openTabAgents: ["claude-box"]), [],
                       "a new agent renames nothing")
    }
}
