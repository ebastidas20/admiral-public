import XCTest
@testable import AdmiralCore

/// Which PATH an ACP agent (and its exec runner) is launched with — a Finder-launched Admiral
/// inherits launchd's, which finds no `/usr/local/bin/docker`.
final class LaunchEnvironmentTests: XCTestCase {
    private let minimal = ["PATH": "/usr/bin:/bin", "HOME": "/Users/x"]

    func testTheAgentsOwnPathWins() {
        let env = LaunchEnvironment.make(
            base: minimal, overrides: ["PATH": "/agent/bin", "K": "v"], loginPath: { "/login/bin" })
        XCTAssertEqual(env["PATH"], "/agent/bin")
        XCTAssertEqual(env["K"], "v")
        XCTAssertEqual(env["HOME"], "/Users/x")
    }

    func testElseTheLoginShellsPath() {
        let env = LaunchEnvironment.make(base: minimal, overrides: [:], loginPath: { "/login/bin:/usr/bin" })
        XCTAssertEqual(env["PATH"], "/login/bin:/usr/bin")
    }

    func testElseTheInheritedPathPlusTheCommonDirs() {
        XCTAssertEqual(
            LaunchEnvironment.make(base: minimal, overrides: [:], loginPath: { nil })["PATH"],
            "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin")
        XCTAssertEqual(
            LaunchEnvironment.path(configured: "", loginPath: { "" }, inherited: "/usr/local/bin:/bin"),
            "/usr/local/bin:/bin:/opt/homebrew/bin", "no dir twice; empty values do not count")
        XCTAssertEqual(
            LaunchEnvironment.path(configured: nil, loginPath: { nil }, inherited: nil),
            "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin")
    }

    /// The login shell is read once, off the caller: nil until it answers, then cached.
    func testLoginShellPathIsReadOnceInTheBackgroundAndNeverBlocks() {
        let gate = DispatchSemaphore(value: 0)
        let reads = Counter()
        let path = LoginShellPath {
            reads.bump()
            gate.wait()
            return "/login/bin"
        }
        XCTAssertNil(path.current(), "never waits on the shell")
        gate.signal()
        let deadline = Date().addingTimeInterval(3)
        while path.current() == nil, Date() < deadline { usleep(2_000) }
        XCTAssertEqual(path.current(), "/login/bin")
        XCTAssertEqual(reads.value, 1)
    }

    func testExecRunnerLaunchesItsPrefixOnTheDecidedPath() throws {
        let dir = try ToolDir(name: "fake-docker", script: "echo \"in-box $*\"")
        defer { dir.remove() }
        let runner = ExecCommandRunner(
            exec: AcpCommand(command: "fake-docker", args: ["exec", "box"]),
            baseEnvironment: minimal, loginPath: { dir.url.path + ":/usr/bin:/bin" })
        let out = runner.run(["git", "--version"], cwd: nil, timeout: 5)
        XCTAssertEqual(out?.code, 0)
        XCTAssertEqual(out?.stdout, "in-box exec box git --version\n")
        let pinned = ExecCommandRunner(
            exec: AcpCommand(command: "fake-docker"), configuredPath: "/agent/bin",
            baseEnvironment: minimal, loginPath: { "/login/bin" })
        XCTAssertEqual(pinned.environment["PATH"], "/agent/bin")
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.withLock { n } }
    func bump() { lock.withLock { n += 1 } }
}

/// A temp dir holding one executable `sh` script — a binary that lives only off the PATH.
struct ToolDir {
    let url: URL

    init(name: String, script: String) throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("tool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let file = url.appendingPathComponent(name)
        try "#!/bin/sh\n\(script)\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}
