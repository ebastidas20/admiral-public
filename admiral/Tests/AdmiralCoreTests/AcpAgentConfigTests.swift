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
    private let id = UUID()

    private func decode(_ json: String) throws -> AcpAgentConfig {
        try JSONDecoder().decode(AcpAgentConfig.self, from: Data(json.utf8))
    }

    /// The previous version's shape: no `workspace`, an optional `exec`, a `defaultMode`.
    private func legacyJSON(
        launch: String = #"{"command":"docker","args":["exec","-i","-w","/w","box","npx","x"]}"#,
        exec: String? = nil, defaultMode: String? = #""bypassPermissions""#, options: String = "{}",
        callback: String? = #""http://host.docker.internal:4142""#
    ) -> String {
        var fields = [#""id":"\#(id.uuidString)""#, #""name":"a""#, #""launch":\#(launch)"#, #""env":{}"#,
                      #""cwd":"/w""#, #""defaultConfigOptions":\#(options)"#]
        if let exec { fields.append(#""exec":\#(exec)"#) }
        if let defaultMode { fields.append(#""defaultMode":\#(defaultMode)"#) }
        if let callback { fields.append(#""mcpCallbackURL":\#(callback)"#) }
        return "{" + fields.joined(separator: ",") + "}"
    }

    func testLegacyJSONWithoutWorkspaceDerivesExecOnce() throws {
        let c = try decode(legacyJSON())
        XCTAssertEqual(c.workspace, .elsewhere(exec: AcpCommand(command: "docker", args: ["exec", "-w", "/w", "box"])))
        XCTAssertEqual(c.execRunnerCommand, AcpCommand(command: "docker", args: ["exec", "-w", "/w", "box"]))
        XCTAssertEqual(c.defaultConfigOptions, ["mode": "bypassPermissions"])
        XCTAssertEqual(c.mcpCallbackURL, "http://host.docker.internal:4142")
        XCTAssertEqual(c.id, id)
    }

    func testLegacyDerivationHandlesUserFlagAndCombinedIT() throws {
        let c = try decode(legacyJSON(launch: #"{"command":"docker","args":["exec","-it","-u","node","box","a"]}"#))
        XCTAssertEqual(c.workspace, .elsewhere(exec: AcpCommand(command: "docker", args: ["exec", "-u", "node", "box"])))
    }

    func testLegacyNonDockerLaunchHasNoExec() throws {
        let c = try decode(legacyJSON(launch: #"{"command":"ssh","args":["host","agent"]}"#))
        XCTAssertEqual(c.workspace, .elsewhere(exec: nil))
        XCTAssertNil(c.execRunnerCommand)
    }

    func testLegacyExplicitExecWins() throws {
        let c = try decode(legacyJSON(exec: #"{"command":"ssh","args":["h"]}"#))
        XCTAssertEqual(c.workspace, .elsewhere(exec: AcpCommand(command: "ssh", args: ["h"])))
    }

    func testLegacyModeDoesNotOverrideOption() throws {
        let c = try decode(legacyJSON(defaultMode: #""plan""#, options: #"{"mode":"default"}"#))
        XCTAssertEqual(c.defaultConfigOptions, ["mode": "default"])
        let none = try decode(legacyJSON(defaultMode: "null", options: #"{"model":"opus"}"#))
        XCTAssertEqual(none.defaultConfigOptions, ["model": "opus"], "a null mode adds nothing")
    }

    func testLegacyMissingCallbackKeepsOldDefault() throws {
        let c = try decode(legacyJSON(callback: nil))
        XCTAssertEqual(c.mcpCallbackURL, "http://host.docker.internal:4142")
    }

    func testEncodeRoundTripWritesNewShape() throws {
        let configs = [
            try decode(legacyJSON()),
            AcpAgentConfig(name: "m", launch: AcpCommand(command: "npx", args: ["-y", "p@1"]), cwd: "/p"),
            AcpAgentConfig(name: "s", launch: AcpCommand(command: "ssh"), cwd: "/p", workspace: .elsewhere(exec: nil),
                           mcpCallbackURL: "http://127.0.0.1:4142"),
        ]
        for config in configs {
            let data = try JSONEncoder().encode(config)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertNotNil(object["workspace"])
            XCTAssertNil(object["exec"])
            XCTAssertNil(object["defaultMode"])
            XCTAssertEqual(try JSONDecoder().decode(AcpAgentConfig.self, from: data), config)
        }
    }

    func testWorkspaceJSONShape() throws {
        func json(_ w: AcpWorkspace) throws -> String {
            let e = JSONEncoder()
            e.outputFormatting = .sortedKeys
            return String(decoding: try e.encode(w), as: UTF8.self)
        }
        XCTAssertEqual(try json(.thisMac), #"{"kind":"thisMac"}"#)
        XCTAssertEqual(try json(.elsewhere(exec: nil)), #"{"kind":"elsewhere"}"#)
        XCTAssertEqual(try json(.elsewhere(exec: AcpCommand(command: "ssh", args: ["h"]))),
                       #"{"exec":{"args":["h"],"command":"ssh"},"kind":"elsewhere"}"#)
        XCTAssertThrowsError(try JSONDecoder().decode(AcpWorkspace.self, from: Data(#"{"kind":"moon"}"#.utf8)))
    }

    func testThisMacDefaults() {
        let c = AcpAgentConfig(name: "a", launch: AcpCommand(command: "npx"), cwd: "/p")
        XCTAssertEqual(c.workspace, .thisMac)
        XCTAssertEqual(c.mcpCallbackURL, "http://127.0.0.1:4142")
        XCTAssertTrue(c.defaultConfigOptions.isEmpty)
        XCTAssertTrue(c.env.isEmpty)
        XCTAssertNil(c.execRunnerCommand)
        XCTAssertEqual(c.validationErrors, [])
    }

    func testElsewhereRequiresBridgeURL() {
        var c = AcpAgentConfig(name: "a", launch: AcpCommand(command: "ssh"), cwd: "/p", workspace: .elsewhere(exec: nil))
        XCTAssertEqual(c.mcpCallbackURL, "")
        XCTAssertEqual(c.validationErrors, ["bridge URL is required when the agent runs elsewhere"])
        c.mcpCallbackURL = "http://host.docker.internal:4142"
        XCTAssertEqual(c.validationErrors, [])
    }

    func testBridgeURLMustBeHTTP() {
        var c = AcpAgentConfig(name: "a", launch: AcpCommand(command: "ssh"), cwd: "/p", workspace: .elsewhere(exec: nil))
        for bad in ["host.docker.internal:4142", "ftp://h:4142", "http://", "http://h:4142/mcp", "nonsense"] {
            c.mcpCallbackURL = bad
            XCTAssertEqual(c.validationErrors, ["bridge URL must be an http:// URL"], bad)
        }
        for good in ["http://h:4142", "https://h", "http://10.0.0.2:4142/"] {
            c.mcpCallbackURL = good
            XCTAssertEqual(c.validationErrors, [], good)
        }
        var mac = AcpAgentConfig(name: "a", launch: AcpCommand(command: "npx"), cwd: "/p")
        mac.mcpCallbackURL = "nonsense"
        XCTAssertEqual(mac.validationErrors, ["bridge URL must be an http:// URL"])
    }

    func testNonDockerLaunchIsNotParsed() {
        let c = AcpAgentConfig(
            name: "a", launch: AcpCommand(command: "docker", args: ["exec", "-i", "box", "agent"]), cwd: "/w",
            workspace: .elsewhere(exec: nil), mcpCallbackURL: "http://h:4142")
        XCTAssertNil(c.execRunnerCommand, "a new config never guesses an exec from its launch")
        let decoded = try? JSONDecoder().decode(AcpAgentConfig.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(decoded?.workspace, .elsewhere(exec: nil), "nor does decoding the new shape")
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

    func testDefaultAgentResolvesOnlyWhileTheAgentExists() {
        let suite = "AcpAgentConfigTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AcpAgentStore(defaults: defaults)
        XCTAssertNil(store.defaultAgent())
        let agent = AcpAgentConfig.sample
        store.save([agent])
        store.defaultAgentID = agent.id
        XCTAssertEqual(store.defaultAgent()?.id, agent.id)
        store.save([])
        XCTAssertNil(store.defaultAgent())  // a deleted agent means Claude Code, not a dangling pick
        store.defaultAgentID = nil
        XCTAssertNil(defaults.string(forKey: "admiral.acpDefaultAgent.v1"))
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

    /// A launch whose log holds only Admiral's traced traffic has no agent reason — even when
    /// the tail read starts in the middle of a traced line. Its end is not the agent's words: in
    /// the Task 12 run it put a fragment of `_auth/status_update` (the account's email) on the tab.
    func testLastAgentLineIgnoresAFragmentOfAdmiralsOwnLine() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("acp-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("t.log")
        for i in 0..<10 {
            AcpLog.append("acp: <- {\"n\":\(i),\"pad\":\"" + String(repeating: "y", count: 1_000 + i) + "\"}", to: log)
        }
        AcpLog.append("acp: agent connection closed", to: log)
        XCTAssertGreaterThan(AcpLog.size(log), AcpLog.tailBytes)
        XCTAssertNil(AcpLog.lastAgentLine(log, after: 0))
    }

    func testDraftRoundTripsAConfig() {
        let elsewhere = AcpAgentConfig(
            name: "PPT", launch: AcpCommand(command: "docker", args: ["exec", "-i", "-e", "A=b c", "box", "agent"]),
            env: ["PATH": "/opt/bin:/usr/bin", "TOKEN": "x=y"], cwd: "/workspace",
            workspace: .elsewhere(exec: AcpCommand(command: "docker", args: ["exec", "box"])),
            defaultConfigOptions: ["model": "opus"], mcpCallbackURL: "http://host.docker.internal:4142")
        XCTAssertEqual(AcpAgentDraft(elsewhere).config, elsewhere)
        var none = elsewhere
        none.workspace = .elsewhere(exec: nil)
        XCTAssertEqual(AcpAgentDraft(none).config, none)
        let mac = AcpAgentConfig(name: "m", launch: AcpCommand(command: "npx", args: ["-y", "p@1"]), cwd: "/p")
        XCTAssertEqual(AcpAgentDraft(mac).config, mac)
    }

    func testDraftNewIsThisMacWithEmptyFields() {
        let draft = AcpAgentDraft.new()
        XCTAssertEqual(draft.workspace, .thisMac)
        XCTAssertEqual(draft.cwd, "", "no path pre-filled")
        XCTAssertEqual(draft.name, "")
        XCTAssertEqual(draft.command, "")
        XCTAssertEqual(draft.exec.values, [])
        XCTAssertEqual(draft.configOptions.map, [:])
        XCTAssertEqual(draft.config.workspace, .thisMac)
        XCTAssertEqual(draft.config.mcpCallbackURL, "http://127.0.0.1:4142")
    }

    func testDraftSwitchingWorkspaceUpdatesTheBridgeURL() {
        var draft = AcpAgentDraft.new()
        draft.workspace = .elsewhere
        XCTAssertEqual(draft.mcpCallbackURL, "", "This Mac's URL would not reach this Mac from elsewhere")
        XCTAssertEqual(draft.config.validationErrors(among: []).contains(AcpAgentConfig.bridgeURLRequired), true)
        draft.mcpCallbackURL = "http://host.docker.internal:4142"
        draft.exec = AcpArgList(["docker", "exec", "my-container"])
        XCTAssertEqual(draft.config.workspace,
                       .elsewhere(exec: AcpCommand(command: "docker", args: ["exec", "my-container"])))
        draft.workspace = .thisMac
        XCTAssertEqual(draft.mcpCallbackURL, "http://127.0.0.1:4142")
        XCTAssertEqual(draft.config.workspace, .thisMac, "the exec rows do not apply on this Mac")
        draft.workspace = .elsewhere
        XCTAssertEqual(draft.mcpCallbackURL, "")
        draft.mcpCallbackURL = "http://10.0.0.2:4142"
        draft.workspace = .elsewhere
        XCTAssertEqual(draft.mcpCallbackURL, "http://10.0.0.2:4142", "re-choosing Elsewhere keeps a typed URL")
    }

    func testDraftNormalizesRows() {
        var draft = AcpAgentDraft.new()
        XCTAssertEqual(draft.args.rows.count, 1, "an empty list shows one empty row")
        XCTAssertEqual(draft.env.rows.count, 1)
        draft.name = " PPT "
        draft.command = "docker"
        draft.args = AcpArgList(["exec", "  -i", "", "   ", "box", "npx -y pkg@1.2.3", ""])
        draft.env = AcpRowList([AcpPair(key: "FOO", value: "bar=baz"), AcpPair(key: "", value: "nokey"),
                                AcpPair(key: " BAR ", value: " 1")], blank: AcpPair())
        draft.workspace = .elsewhere
        let config = draft.config
        XCTAssertEqual(config.name, "PPT")
        XCTAssertEqual(config.launch.args, ["exec", "-i", "box", "npx -y pkg@1.2.3"],
                       "blank rows dropped, inner spaces kept: one row is one arg")
        XCTAssertEqual(config.env, ["FOO": "bar=baz", "BAR": " 1"], "empty key dropped, value as typed")
        XCTAssertEqual(config.workspace, .elsewhere(exec: nil), "empty exec rows = none, never derived")
        XCTAssertEqual(draft.validationErrors, [])
    }

    func testArgListAddRemoveMove() {
        var list = AcpArgList(["a", "b", "c"])
        let ids = list.rows.map(\.id)
        let added = list.append()
        XCTAssertEqual(list.rows.map(\.item), ["a", "b", "c", ""])
        list[added] = "d e"
        XCTAssertEqual(list.values, ["a", "b", "c", "d e"])
        list.move(ids[0], by: 1)
        XCTAssertEqual(list.values, ["b", "a", "c", "d e"])
        list.move(added, by: 1)
        XCTAssertEqual(list.values, ["b", "a", "c", "d e"], "past the end is a no-op")
        XCTAssertFalse(list.canMove(added, by: 1))
        XCTAssertFalse(list.canMove(ids[1], by: -1))
        XCTAssertTrue(list.canMove(ids[1], by: 1))
        list.remove(ids[2])
        XCTAssertEqual(list.values, ["b", "a", "d e"])
        for row in list.rows { list.remove(row.id) }
        XCTAssertEqual(list.rows.count, 1, "never no rows")
        XCTAssertEqual(list.values, [])
        XCTAssertEqual(AcpArgList([]).values, [])
    }

    func testPairListDuplicateKeysAreAnErrorNotLastWins() {
        var list = AcpPairList(["B": "2", "A": "1"])
        XCTAssertEqual(list.rows.map(\.item.key), ["A", "B"], "opens sorted by key")
        let id = list.append()
        list[id] = AcpPair(key: " A ", value: "3")
        XCTAssertEqual(list.duplicateKeys, ["A"])
        XCTAssertEqual(list.map, ["A": "1", "B": "2"])
        var draft = AcpAgentDraft.new()
        draft.env = list
        draft.configOptions = AcpRowList([AcpPair(key: "model", value: "opus"),
                                          AcpPair(key: "model", value: "sonnet")], blank: AcpPair())
        XCTAssertEqual(draft.validationErrors, [
            "The environment variable \u{201C}A\u{201D} is set more than once.",
            "The config option \u{201C}model\u{201D} is set more than once.",
        ])
        list.remove(id)
        XCTAssertEqual(list.duplicateKeys, [])
        list.move(list.rows[1].id, by: -1)
        XCTAssertEqual(list.pairs.map(\.key), ["B", "A"])
    }

    /// R14: deleting an agent a tab is open on breaks that tab the same way a rename does, so
    /// it is refused too (same case-insensitive match); with no tab on it, delete is fine.
    func testDeleteIsRefusedWhileATabUsesTheAgent() {
        let saved = AcpAgentConfig.sample
        XCTAssertEqual(saved.deletionError(openTabAgents: [" CLAUDE-BOX "]), AcpAgentConfig.deleteWithOpenTabs)
        XCTAssertEqual(AcpAgentConfig.deleteWithOpenTabs, "Close this agent's tabs before deleting it.")
        XCTAssertNil(saved.deletionError(openTabAgents: ["other"]))
        XCTAssertNil(saved.deletionError(openTabAgents: []))
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
