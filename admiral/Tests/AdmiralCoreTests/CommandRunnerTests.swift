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

    func testExecRunnerDefaultsToTheFiveSecondBoundAndLocalStaysUnbounded() {
        XCTAssertEqual(ExecCommandRunner(exec: AcpCommand(command: "docker")).defaultTimeout, 5)
        XCTAssertEqual(LocalCommandRunner().defaultTimeout, .infinity)
    }

    /// Git through a hung exec gives up at the runner's bound instead of pinning the thread.
    func testGitThroughHangingExecReturnsNilWithinTheBound() {
        // `sh -c 'sleep 10' sh git …` — the "exec" prefix hangs whatever git it is handed.
        let hung = ExecCommandRunner(exec: AcpCommand(command: "sh", args: ["-c", "sleep 10", "sh"]),
                                     defaultTimeout: 0.5)
        let start = Date()
        XCTAssertNil(Git.repoRoot(at: "/workspace", runner: hung))
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

    /// More than a pipe buffer on stdout: the runner drains it while the command runs, so the
    /// writer never blocks, the command exits, and every byte comes back — well inside the bound.
    func testLocalRunnerReturnsOutputLargerThanAPipeBuffer() {
        let start = Date()
        let out = LocalCommandRunner().run(["sh", "-c", "head -c 200000 /dev/zero | tr '\\0' a"],
                                           cwd: nil, timeout: 5)
        XCTAssertEqual(out?.code, 0)
        XCTAssertEqual(out?.stdout.utf8.count, 200_000)
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
    }

    /// The same through the exec path gh takes in an agent's environment — and a full stderr
    /// pipe must not wedge it either.
    func testExecRunnerReturnsLargeStdoutAndStderr() {
        let runner = ExecCommandRunner(exec: AcpCommand(command: "env", args: []))
        let script = "head -c 200000 /dev/zero | tr '\\0' a; head -c 100000 /dev/zero | tr '\\0' e >&2; exit 4"
        let out = runner.runCapturingStderr(["sh", "-c", script], cwd: nil, timeout: 5)
        XCTAssertEqual(out?.code, 4)
        XCTAssertEqual(out?.stdout.utf8.count, 200_000)
        XCTAssertEqual(out?.stderr.utf8.count, 100_000)
    }

    /// stderr is surfaced, so gh's "rate limit" and merge errors reach GitHubService.
    func testRunnerSurfacesStderr() {
        let out = LocalCommandRunner().runCapturingStderr(["sh", "-c", "echo 'API rate limit exceeded' >&2; exit 1"],
                                                          cwd: nil, timeout: 5)
        XCTAssertEqual(out, CommandOutput(code: 1, stdout: "", stderr: "API rate limit exceeded\n"))
    }
}
