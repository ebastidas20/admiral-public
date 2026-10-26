import XCTest
@testable import AdmiralCore

/// `~/.claude.json` trust for an API tool tab. Every file lives under a temp dir
/// this test creates and deletes — nothing here touches the real home config.
final class ClientToolClaudeProjectTrustTests: XCTestCase {
    private var dir: URL!
    private var config: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-trust-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let claudeHome = dir.appendingPathComponent(".claude")
        config = ClaudeProjectTrust.configURL(claudeHome: claudeHome)
    }

    override func tearDown() {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func root() throws -> [String: Any] {
        let data = try Data(contentsOf: config)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func projects() throws -> [String: Any] {
        try XCTUnwrap(try root()["projects"] as? [String: Any])
    }

    private func entry(_ cwd: String) throws -> [String: Any] {
        try XCTUnwrap(try projects()[ClaudeProjectTrust.projectKey(for: cwd)] as? [String: Any])
    }

    func testConfigURLIsTheSiblingOfClaudeHome() {
        XCTAssertEqual(config.path, dir.appendingPathComponent(".claude.json").path)
        XCTAssertTrue(config.path.hasPrefix(dir.path))
    }

    func testProjectKeyExpandsTildeAndDropsATrailingSlash() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(ClaudeProjectTrust.projectKey(for: "~/code/client-app"),
                       home + "/code/client-app")
        XCTAssertEqual(ClaudeProjectTrust.projectKey(for: "/tmp/proj/"), "/tmp/proj")
        XCTAssertEqual(ClaudeProjectTrust.projectKey(for: "/tmp/a/../b"), "/tmp/a/../b",
                       "Claude does not normalize the projects key; .. stays")
        let relative = ClaudeProjectTrust.projectKey(for: "lg-test")
        XCTAssertTrue((relative as NSString).isAbsolutePath)
        XCTAssertTrue(relative.hasSuffix("/lg-test"))
    }

    func testMissingFileCreatesATrustedProjectEntry() throws {
        let cwd = dir.appendingPathComponent("client-app").path
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.path))
        XCTAssertTrue(ClaudeProjectTrust.ensureAccepted(cwd: cwd, claudeConfigURL: config))

        let parsed = try root()
        XCTAssertEqual(Set(parsed.keys), ["projects"])
        let project = try entry(cwd)
        XCTAssertEqual(project["hasTrustDialogAccepted"] as? Bool, true)
        XCTAssertEqual((project["allowedTools"] as? [Any])?.count, 0)
        XCTAssertEqual((project["mcpServers"] as? [String: Any])?.count, 0)
        XCTAssertEqual((project["mcpContextUris"] as? [Any])?.count, 0)
        XCTAssertEqual((project["enabledMcpjsonServers"] as? [Any])?.count, 0)
        XCTAssertEqual((project["disabledMcpjsonServers"] as? [Any])?.count, 0)
        XCTAssertEqual(project["projectOnboardingSeenCount"] as? Int, 0)
        XCTAssertEqual(project["hasClaudeMdExternalIncludesApproved"] as? Bool, false)
        XCTAssertEqual(project["hasClaudeMdExternalIncludesWarningShown"] as? Bool, false)
        let mode = try FileManager.default.attributesOfItem(atPath: config.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((mode?.intValue ?? 0) & 0o777, 0o600)
    }

    func testExistingProjectWithoutTheFlagIsMarkedAndSiblingsStay() throws {
        let cwd = "/Users/me/code/client-app"
        let original: [String: Any] = [
            "numStartups": 7,
            "autoUpdates": false,
            "theme": "dark",
            "tipsHistory": ["new-user-warmup": 2],
            "projects": [
                "/Users/me/code/other-app": [
                    "allowedTools": ["Bash"],
                    "mcpServers": ["bridge": ["command": "admiral-bridge-mcp"]],
                    "hasTrustDialogAccepted": false,
                    "note": "other",
                ] as [String: Any],
                cwd: [
                    "allowedTools": ["Read"],
                    "mcpServers": ["local": ["command": "echo"]],
                    "hasTrustDialogAccepted": false,
                    "custom": "stay",
                ] as [String: Any],
            ] as [String: Any],
        ]
        let data = try JSONSerialization.data(withJSONObject: original, options: [.prettyPrinted])
        try data.write(to: config)

        XCTAssertTrue(ClaudeProjectTrust.ensureAccepted(cwd: cwd, claudeConfigURL: config))

        let parsed = try root()
        XCTAssertEqual(parsed["numStartups"] as? Int, 7)
        XCTAssertEqual(parsed["autoUpdates"] as? Bool, false)
        XCTAssertEqual(parsed["theme"] as? String, "dark")
        let tips = try XCTUnwrap(parsed["tipsHistory"] as? [String: Any])
        XCTAssertEqual(tips["new-user-warmup"] as? Int, 2)

        let project = try entry(cwd)
        XCTAssertEqual(project["hasTrustDialogAccepted"] as? Bool, true)
        XCTAssertEqual(project["custom"] as? String, "stay")
        XCTAssertEqual(project["allowedTools"] as? [String], ["Read"])
        let servers = try XCTUnwrap(project["mcpServers"] as? [String: Any])
        let local = try XCTUnwrap(servers["local"] as? [String: Any])
        XCTAssertEqual(local["command"] as? String, "echo")

        let other = try XCTUnwrap(try projects()["/Users/me/code/other-app"] as? [String: Any])
        XCTAssertEqual(other["hasTrustDialogAccepted"] as? Bool, false)
        XCTAssertEqual(other["note"] as? String, "other")
        XCTAssertEqual(other["allowedTools"] as? [String], ["Bash"])
        let bridge = try XCTUnwrap((other["mcpServers"] as? [String: Any])?["bridge"] as? [String: Any])
        XCTAssertEqual(bridge["command"] as? String, "admiral-bridge-mcp")
    }

    /// The file is already there and the folder is not. The new entry is the
    /// minimal shape; the rest of the config stays.
    func testMissingProjectEntryIsInserted() throws {
        let cwd = dir.appendingPathComponent("new-api-cwd").path
        let original: [String: Any] = [
            "numStartups": 4,
            "projects": [
                "/keep": ["hasTrustDialogAccepted": true, "allowedTools": [String]()] as [String: Any],
            ],
        ]
        try JSONSerialization.data(withJSONObject: original).write(to: config)

        XCTAssertTrue(ClaudeProjectTrust.ensureAccepted(cwd: cwd, claudeConfigURL: config))

        let parsed = try root()
        XCTAssertEqual(parsed["numStartups"] as? Int, 4)
        let project = try entry(cwd)
        XCTAssertEqual(project["hasTrustDialogAccepted"] as? Bool, true)
        XCTAssertEqual((project["allowedTools"] as? [Any])?.count, 0)
        XCTAssertEqual((project["mcpServers"] as? [String: Any])?.count, 0)
        let kept = try XCTUnwrap(try projects()["/keep"] as? [String: Any])
        XCTAssertEqual(kept["hasTrustDialogAccepted"] as? Bool, true)
    }

    func testAlreadyAcceptedEntryIsLeftAlone() throws {
        let cwd = "/tmp/already"
        let text = """
        { "theme" : "dark",
          "projects" : { "\(cwd)" : { "zzz" : "keep", "hasTrustDialogAccepted" : true } } }

        """
        try text.write(to: config, atomically: true, encoding: .utf8)
        let before = try Data(contentsOf: config)

        XCTAssertTrue(ClaudeProjectTrust.ensureAccepted(cwd: cwd, claudeConfigURL: config))
        XCTAssertEqual(try Data(contentsOf: config), before)

        XCTAssertTrue(ClaudeProjectTrust.ensureAccepted(cwd: cwd + "/", claudeConfigURL: config))
        XCTAssertEqual(try Data(contentsOf: config), before, "a trailing slash is the same project")
    }

    func testUnreadableShapeIsNotReplaced() throws {
        let junk = "{ this is not json\n"
        try junk.write(to: config, atomically: true, encoding: .utf8)
        XCTAssertFalse(ClaudeProjectTrust.ensureAccepted(cwd: "/tmp/x", claudeConfigURL: config))
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), junk)

        let projectsArray = "{\"projects\":[]}\n"
        try projectsArray.write(to: config, atomically: true, encoding: .utf8)
        XCTAssertFalse(ClaudeProjectTrust.ensureAccepted(cwd: "/tmp/x", claudeConfigURL: config))
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), projectsArray)

        let badEntry = "{\"numStartups\":1,\"projects\":{\"/tmp/x\":\"nope\"}}\n"
        try badEntry.write(to: config, atomically: true, encoding: .utf8)
        XCTAssertFalse(ClaudeProjectTrust.ensureAccepted(cwd: "/tmp/x", claudeConfigURL: config))
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), badEntry)
    }

    func testBlankCwdDoesNotCreateAFile() {
        XCTAssertFalse(ClaudeProjectTrust.ensureAccepted(cwd: "   ", claudeConfigURL: config))
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.path))
    }
}

/// The API scratch path is the only commission that may write the trust flag,
/// and it has to land before the process starts — the dialog is what blocks the
/// session file.
@MainActor
final class ClientToolProjectTrustTests: XCTestCase {
    private var dir: URL!
    private var claudeHome: URL!
    private var config: URL!
    private var cwd: String!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-trust-spawn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        claudeHome = dir.appendingPathComponent(".claude")
        config = ClaudeProjectTrust.configURL(claudeHome: claudeHome)
        cwd = dir.appendingPathComponent("client-app").path
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: cwd), withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func manager(host: TerminalHost) -> SessionManager {
        SessionManager(
            host: host, claudeHome: claudeHome, executablePath: "/usr/bin/claude",
            supportDir: dir.appendingPathComponent("support"))
    }

    private func tool() -> ClientToolSpec {
        ClientToolSpec(name: "get_lucky_number", description: "Always 7.",
                       inputSchema: .object(["type": .string("object")]))
    }

    func testClientToolScratchTabTrustsCwdBeforeSpawn() throws {
        let project = try XCTUnwrap(cwd)
        let seeded: [String: Any] = [
            "numStartups": 3,
            "projects": [
                "/keep": [
                    "hasTrustDialogAccepted": false,
                    "allowedTools": ["Bash"],
                ] as [String: Any],
                project: [
                    "allowedTools": ["Read"],
                    "note": "stay",
                ] as [String: Any],
            ] as [String: Any],
        ]
        try JSONSerialization.data(withJSONObject: seeded).write(to: config)

        let host = TrustObservingHost(cwd: cwd, config: config)
        let tab = manager(host: host).createScratchTab(
            sessionID: UUID().uuidString.lowercased(), cwd: cwd, model: nil, clientTools: [tool()])

        XCTAssertNotNil(tab)
        XCTAssertEqual(host.spawnedCwd, cwd)
        XCTAssertEqual(host.trustedAtSpawn, true)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any])
        XCTAssertEqual(root["numStartups"] as? Int, 3)
        let projects = try XCTUnwrap(root["projects"] as? [String: Any])
        let entry = try XCTUnwrap(projects[project] as? [String: Any])
        XCTAssertEqual(entry["hasTrustDialogAccepted"] as? Bool, true)
        XCTAssertEqual(entry["note"] as? String, "stay")
        XCTAssertEqual(entry["allowedTools"] as? [String], ["Read"])
        let other = try XCTUnwrap(projects["/keep"] as? [String: Any])
        XCTAssertEqual(other["hasTrustDialogAccepted"] as? Bool, false)
    }

    func testScratchTabWithoutClientToolsDoesNotTouchClaudeConfig() throws {
        let host = TrustObservingHost(cwd: cwd, config: config)
        let mgr = manager(host: host)
        let plain = mgr.createScratchTab(
            sessionID: UUID().uuidString.lowercased(), cwd: cwd, model: nil, clientTools: nil)
        XCTAssertNotNil(plain)
        XCTAssertEqual(host.spawnCount, 1)
        XCTAssertEqual(host.trustedAtSpawn, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.path))

        let seeded = Data("{\"theme\":\"dark\"}\n".utf8)
        try seeded.write(to: config)
        _ = mgr.commission(callsign: "fleet", cwd: cwd)
        XCTAssertEqual(try Data(contentsOf: config), seeded)
        XCTAssertEqual(host.spawnCount, 2)
    }
}

@MainActor
private final class TrustObservingHost: TerminalHost {
    let cwd: String
    let config: URL
    private(set) var trustedAtSpawn: Bool?
    private(set) var spawnedCwd: String?
    private(set) var spawnCount = 0

    init(cwd: String, config: URL) {
        self.cwd = cwd
        self.config = config
    }

    func spawn(
        executable: String, args: [String], env: [String: String], cwd: String,
        onExit: @escaping @Sendable (Int32?) -> Void
    ) -> TerminalHandle {
        spawnCount += 1
        spawnedCwd = cwd
        trustedAtSpawn = Self.accepted(config: config, cwd: self.cwd)
        return Handle()
    }

    func send(_ handle: TerminalHandle, text: String) {}

    private static func accepted(config: URL, cwd: String) -> Bool {
        guard let data = try? Data(contentsOf: config),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = root["projects"] as? [String: Any],
              let entry = projects[cwd] as? [String: Any] else { return false }
        return (entry["hasTrustDialogAccepted"] as? Bool) == true
    }

    final class Handle: TerminalHandle { let pid: Int32? = 11 }
}
