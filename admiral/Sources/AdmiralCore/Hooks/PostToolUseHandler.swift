import Foundation

/// Handles a Claude Code `PostToolUse` payload. For a file-write tool, resolves the written
/// file's git repo + branch with local git and appends a `TouchedRepoEvent` to the session
/// log. Cheap and local only — PostToolUse hooks block the agent, so no network here.
public enum PostToolUseHandler {
    public static let writeTools: Set<String> = ["Write", "Edit", "MultiEdit", "NotebookEdit"]

    /// `runner` is where git runs — this Mac, or an ACP agent's environment, whose paths the
    /// payload then carries.
    public static func handle(payload: Data, base: URL, token: String,
                              now: () -> String = PostToolUseHandler.timestamp,
                              runner: CommandRunner = LocalCommandRunner()) {
        guard let obj = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let tool = obj["tool_name"] as? String, writeTools.contains(tool) else { return }
        let input = obj["tool_input"] as? [String: Any] ?? [:]
        let cwd = obj["cwd"] as? String ?? ""
        guard let rawPath = (input["file_path"] as? String) ?? (input["notebook_path"] as? String),
              !rawPath.isEmpty else { return }
        let absPath = rawPath.hasPrefix("/") ? rawPath : (cwd as NSString).appendingPathComponent(rawPath)
        let fileDir = (absPath as NSString).deletingLastPathComponent
        let repoRoot = Git.repoRoot(at: fileDir, runner: runner)
        let branch = repoRoot.flatMap { Git.branch(at: $0, runner: runner) }
        let sessionRoot = cwd.isEmpty ? nil : Git.repoRoot(at: cwd, runner: runner)
        let inside = repoRoot != nil && repoRoot == sessionRoot
        let event = TouchedRepoEvent(
            ts: now(), tool: tool, filePath: absPath,
            repoRoot: repoRoot, branch: branch, insideSessionRoot: inside)
        HookLog.append(event, to: AdmiralPaths.touchedLog(base: base, token: token))
    }

    public static func timestamp() -> String { ISO8601DateFormatter().string(from: Date()) }
}
