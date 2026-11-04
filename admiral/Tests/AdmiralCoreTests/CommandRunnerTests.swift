import XCTest
@testable import AdmiralCore

final class CommandRunnerTests: XCTestCase {
    func testExecRunnerPrefixesArgv() {
        let runner = ExecCommandRunner(exec: AcpCommand(command: "docker", args: ["exec", "-w", "/w", "box"]))
        XCTAssertEqual(runner.argv(for: ["git", "--version"], cwd: nil),
                       ["docker", "exec", "-w", "/w", "box", "git", "--version"])
    }

    /// A cwd becomes a `cd` inside the agent's environment — single-quoted, so a path with a
    /// quote or a `$` reaches `cd` as written — and the command keeps its own argv via `"$@"`.
    func testExecRunnerWrapsCwdInShAfterThePrefix() {
        let runner = ExecCommandRunner(exec: AcpCommand(command: "docker", args: ["exec", "box"]))
        XCTAssertEqual(runner.argv(for: ["git", "status"], cwd: "/w/it's $HOME"),
                       ["docker", "exec", "box", "sh", "-c", #"cd '/w/it'\''s $HOME' && exec "$@""#, "sh",
                        "git", "status"])
    }

    func testLocalRunnerReturnsCodeAndStdout() {
        let out = LocalCommandRunner().run(["sh", "-c", "pwd; exit 3"], cwd: "/usr", timeout: 5)
        XCTAssertEqual(out?.code, 3)
        XCTAssertEqual(out?.stdout, "/usr\n")
    }

    func testLocalRunnerTimesOut() {
        let start = Date()
        let out = LocalCommandRunner().run(["sleep", "10"], cwd: nil, timeout: 0.5)
        XCTAssertNil(out)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    /// The exec runner really launches its prefix with no Mac-side shell: `env` runs as the
    /// "exec" program here, so what reaches the command is exactly the built argv.
    func testExecRunnerRunsThroughThePrefix() {
        let runner = ExecCommandRunner(exec: AcpCommand(command: "env", args: []))
        let out = runner.run(["sh", "-c", "pwd"], cwd: "/usr", timeout: 5)
        XCTAssertEqual(out?.code, 0)
        XCTAssertEqual(out?.stdout, "/usr\n")
    }
}
