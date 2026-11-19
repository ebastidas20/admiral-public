import Foundation
import AdmiralCore

/// Runs `gh` for a session's repo to get its PR's merge-readiness and to merge it.
///
/// Admiral is Finder-launched, so it lacks the user's `PATH`/`GITHUB_TOKEN` (gh auths via
/// that env var, with no stored token). `AdmiralCore.GitHubEnvironment` resolves both — from
/// the environment first, then a login shell — and the `admiral-hook` helper shares it, so
/// `one_pr_per_ticket` authenticates exactly the way the PR chips do. We then run `gh`
/// directly (no shell) so its JSON output is clean. Methods block, so call them off-main.
final class GitHubService: @unchecked Sendable {
    /// A process-wide request/second cap shared by every instance — hence every tab — so a
    /// burst of PR lookups across sessions stays under GitHub's rate limit. `penalize` backs
    /// off further when gh actually reports a limit.
    static let sharedLimiter = GHRateLimiter(maxRequestsPerSecond: 2)
    private let limiter: GHRateLimiter
    /// Where gh runs when it is not this Mac's: an ACP tab's environment, through its exec
    /// command (that environment's gh and its login). Nil = the Mac's gh, with the resolved
    /// PATH and token below. Decided once, here, from the runner handed in.
    private let remote: CommandRunner?

    /// How long gh may run inside an agent's environment. Longer than the exec runner's 5 s
    /// default: a `pr list` with checks, or a merge, is a network round trip, not a local read.
    private static let remoteTimeout: TimeInterval = 30

    init(runner: CommandRunner = LocalCommandRunner(), limiter: GHRateLimiter = GitHubService.sharedLimiter) {
        self.limiter = limiter
        self.remote = runner is LocalCommandRunner ? nil : runner
    }

    // Resolution lives in AdmiralCore.GitHubEnvironment so the `admiral-hook` helper — which
    // cannot link App code — shares exactly this behaviour for `one_pr_per_ticket`.
    private lazy var loginPath = GitHubEnvironment.loginPath()
    private lazy var token = GitHubEnvironment.token()
    private lazy var ghPath = GitHubEnvironment.ghPath(searchPath: loginPath)

    /// The branch's PR status, or nil (no branch / no PR / not a repo / gh failed).
    func prStatus(branch: String, cwd: String) async -> PRStatus? {
        guard !branch.isEmpty else { return nil }
        guard let data = await run([
            "pr", "list", "--head", branch, "--state", "all", "--limit", "20",
            "--json", "number,state,mergeStateStatus,latestReviews,statusCheckRollup,url,title",
        ], cwd: cwd) else { return nil }
        return PRStatus.from(ghJSON: data)
    }

    /// Merge a PR with the repo's preferred method (merge commit → squash → rebase).
    /// Returns an error message on failure, or nil on success.
    func merge(number: Int, cwd: String) async -> String? {
        let result = await runResult(["pr", "merge", "\(number)", await mergeMethodFlag(cwd: cwd)], cwd: cwd)
        return result.code == 0 ? nil : (result.stderr.isEmpty ? "merge failed" : result.stderr)
    }

    private func mergeMethodFlag(cwd: String) async -> String {
        guard let data = await run(["repo", "view", "--json",
                              "mergeCommitAllowed,squashMergeAllowed,rebaseMergeAllowed"], cwd: cwd),
              let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return "--merge" }
        if (d["mergeCommitAllowed"] as? Bool) ?? true { return "--merge" }
        if (d["squashMergeAllowed"] as? Bool) ?? false { return "--squash" }
        if (d["rebaseMergeAllowed"] as? Bool) ?? false { return "--rebase" }
        return "--merge"
    }

    // MARK: - Process plumbing

    private func run(_ args: [String], cwd: String) async -> Data? {
        let r = await runResult(args, cwd: cwd)
        return r.code == 0 ? r.stdout : nil
    }

    /// Every gh invocation funnels through here, so the rate gate is enforced in ONE place:
    /// wait for a slot before launching, and if gh comes back rate-limited, tell the shared
    /// limiter to back off so the other tabs' queued calls slow down too.
    private func runResult(_ args: [String], cwd: String) async -> (code: Int32, stdout: Data, stderr: String) {
        await limiter.acquire()
        if let remote {
            // Same rate-limit back-off and error text as the local path: the runner keeps stderr.
            guard let r = remote.runCapturingStderr(["gh"] + args, cwd: cwd, timeout: Self.remoteTimeout) else {
                return (1, Data(), "gh did not run in the agent's environment")
            }
            if r.code != 0, Self.looksRateLimited(r.stderr) { await limiter.penalize() }
            return (r.code, Data(r.stdout.utf8), r.stderr)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ghPath)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = loginPath
        env["HOME"] = NSHomeDirectory()
        env["GH_PROMPT_DISABLED"] = "1"
        env["NO_COLOR"] = "1"
        if let token { env["GH_TOKEN"] = token; env["GITHUB_TOKEN"] = token }
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return (1, Data(), "\(error)") }
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if p.terminationStatus != 0, Self.looksRateLimited(stderr) { await limiter.penalize() }
        return (p.terminationStatus, stdout, stderr)
    }

    /// gh prints "API rate limit exceeded" / "You have exceeded a secondary rate limit" to
    /// stderr on a 403 — both contain "rate limit".
    private static func looksRateLimited(_ stderr: String) -> Bool {
        stderr.range(of: "rate limit", options: .caseInsensitive) != nil
    }

}
