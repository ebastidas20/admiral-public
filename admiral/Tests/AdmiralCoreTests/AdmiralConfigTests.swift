import XCTest
@testable import AdmiralCore

final class AdmiralConfigTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("admiral-config-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private var url: URL { dir.appendingPathComponent("config.json") }

    func testMissingFileCreatesDefaultsBothFalse() {
        let config = AdmiralConfigStore.load(from: url)
        XCTAssertEqual(config.version, 1)
        XCTAssertFalse(config.features.chatView)
        XCTAssertFalse(config.features.apiServer)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let reloaded = AdmiralConfigStore.load(from: url)
        XCTAssertEqual(reloaded, config)
    }

    func testUnknownKeysIgnoredAndMissingFeaturesDefaultFalse() throws {
        let raw = """
        {"version": 1, "features": {"chatView": true, "extra": 99}, "future": "x"}
        """
        try raw.write(to: url, atomically: true, encoding: .utf8)
        let config = AdmiralConfigStore.load(from: url)
        XCTAssertEqual(config.version, 1)
        XCTAssertTrue(config.features.chatView)
        XCTAssertFalse(config.features.apiServer)
    }

    func testStealthThemeDefaultsOffAndPersists() throws {
        try #"{"version": 1, "features": {"chatView": true}}"#
            .write(to: url, atomically: true, encoding: .utf8)
        var config = AdmiralConfigStore.load(from: url)
        XCTAssertFalse(config.features.stealthTheme)

        config.features.stealthTheme = true
        AdmiralConfigStore.save(config, to: url)
        XCTAssertTrue(AdmiralConfigStore.load(from: url).features.stealthTheme)
    }

    func testRoundTripBothTrue() {
        let config = AdmiralConfig(version: 1, features: .init(chatView: true, apiServer: true))
        AdmiralConfigStore.save(config, to: url)
        XCTAssertEqual(AdmiralConfigStore.load(from: url), config)
    }

    /// Settings → Experimental Features flips a flag; the tickets section written by the
    /// Tickets pane (or by hand) must survive it.
    func testUpdatingFeaturesKeepsTheRestOfTheFile() throws {
        let raw = #"{"version": 1, "features": {"chatView": false, "apiServer": false},"#
            + #" "tickets": {"patterns": ["(PROJ|ACME|KEY)-\\d+\\b"], "openURLTemplate": "https://x/{key}"}}"#
        try raw.write(to: url, atomically: true, encoding: .utf8)

        AdmiralConfigStore.update(at: url) { $0.features.chatView = true }

        let saved = AdmiralConfigStore.load(from: url)
        XCTAssertTrue(saved.features.chatView)
        XCTAssertFalse(saved.features.apiServer)
        XCTAssertEqual(saved.tickets.patterns, [#"(PROJ|ACME|KEY)-\d+\b"#])
        XCTAssertEqual(saved.tickets.openURLTemplate, "https://x/{key}")
    }

    // MARK: - Move from ~/.config/admiral (where the config lived before the support dir)

    private var legacy: URL { dir.appendingPathComponent("legacy/admiral/config.json") }

    private func writeLegacy() throws {
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"version": 1, "features": {"chatView": true, "apiServer": true}}"#
            .write(to: legacy, atomically: true, encoding: .utf8)
    }

    func testLegacyConfigMovesIntoTheSupportDir() throws {
        try writeLegacy()
        XCTAssertTrue(AdmiralConfigStore.migrateLegacyFile(from: legacy, to: url, isolated: false))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.deletingLastPathComponent().path),
                       "the emptied legacy folder goes too")
        let moved = AdmiralConfigStore.load(from: url)
        XCTAssertTrue(moved.features.chatView)
        XCTAssertTrue(moved.features.apiServer)
    }

    func testConfigAlreadyInTheSupportDirWinsAndTheLegacyFileIsKept() throws {
        try writeLegacy()
        AdmiralConfigStore.save(.default, to: url)
        XCTAssertFalse(AdmiralConfigStore.migrateLegacyFile(from: legacy, to: url, isolated: false))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertEqual(AdmiralConfigStore.load(from: url), .default)
    }

    func testIsolatedRunNeverTouchesTheLegacyFile() throws {
        try writeLegacy()
        XCTAssertFalse(AdmiralConfigStore.migrateLegacyFile(from: legacy, to: url, isolated: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testNothingToMoveIsANoOp() {
        XCTAssertFalse(AdmiralConfigStore.migrateLegacyFile(from: legacy, to: url, isolated: false))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// ADMIRAL_SUPPORT_DIR (UI tests, probes) puts the config inside the isolated dir and makes
    /// the move a no-op by default. The legacy file is a temp one, so a broken guard can never
    /// take the real `~/.config/admiral/config.json`.
    func testSupportDirOverrideIsolatesTheConfig() throws {
        try writeLegacy()
        let override = dir.appendingPathComponent("isolated", isDirectory: true)
        setenv("ADMIRAL_SUPPORT_DIR", override.path, 1)
        defer { unsetenv("ADMIRAL_SUPPORT_DIR") }
        XCTAssertEqual(AdmiralConfigStore.defaultURL.path, override.appendingPathComponent("config.json").path)
        XCTAssertFalse(AdmiralConfigStore.migrateLegacyFile(from: legacy))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testChatLedgerDefaultModeIsTerminal() {
        let base = dir.appendingPathComponent("support", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        XCTAssertEqual(ChatLedger.mode(base: base, session: "fresh-session"), .terminal)
    }
}
