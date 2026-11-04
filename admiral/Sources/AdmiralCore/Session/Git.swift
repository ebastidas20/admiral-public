import Foundation

/// Tiny read-only git helper for the status bar / list subtitle and the touched-repos log.
/// `runner` decides where git runs: this Mac by default, or an ACP agent's environment.
enum Git {
    /// No bound: a local git read has always been waited out.
    static let timeout: TimeInterval = .infinity

    static func branch(at cwd: String, runner: CommandRunner = LocalCommandRunner()) -> String? {
        output(["git", "-C", cwd, "symbolic-ref", "--short", "HEAD"], runner: runner)
    }

    static func repoRoot(at cwd: String, runner: CommandRunner = LocalCommandRunner()) -> String? {
        output(["git", "-C", cwd, "rev-parse", "--show-toplevel"], runner: runner)
    }

    /// Trimmed stdout of a successful run; nil on failure or empty output.
    private static func output(_ argv: [String], runner: CommandRunner) -> String? {
        guard let result = runner.run(argv, cwd: nil, timeout: timeout), result.code == 0 else { return nil }
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
