import Foundation

/// Marks a folder trusted in Claude Code's user config so an API tool tab is not
/// blocked on the workspace trust dialog.
///
/// Claude Code asks "Is this a project you created or one you trust?" before it
/// writes a session file or starts MCP. `POST /v1/messages` then sits until
/// `turnTimeout`. The answer is stored at
/// `projects[<absolute cwd>].hasTrustDialogAccepted` in `~/.claude.json` (the
/// sibling of `~/.claude`, not a file inside it). Fleet cwds already have the
/// flag; a new `admiral_cwd` does not. That header is an explicit trust signal
/// for the folder for this session. This writes the flag. It does not type an
/// answer into the dialog, and it does not pass `--dangerously-skip-permissions`.
public enum ClaudeProjectTrust {
    /// `~/.claude.json` lives next to `claudeHome` (`~/.claude`), not inside it.
    public static func configURL(claudeHome: URL) -> URL {
        claudeHome.deletingLastPathComponent().appendingPathComponent(".claude.json")
    }

    /// The `projects` key for `cwd`: `~` expanded, relative paths made absolute,
    /// a trailing slash removed. Symlinks and `..` stay, because Claude keys the
    /// path it was started in and does not normalize it.
    static func projectKey(for cwd: String) -> String {
        var path = (cwd as NSString).expandingTildeInPath
        if !(path as NSString).isAbsolutePath {
            path = (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(path)
        }
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// What Claude Code records the first time it sees a folder, with the trust
    /// dialog already accepted. The shape matches a real `projects` entry
    /// (`allowedTools`, `mcpServers`, and the rest of that default).
    static func newProjectEntry() -> [String: Any] {
        [
            "allowedTools": [String](),
            "mcpContextUris": [String](),
            "mcpServers": [String: Any](),
            "enabledMcpjsonServers": [String](),
            "disabledMcpjsonServers": [String](),
            "hasTrustDialogAccepted": true,
            "projectOnboardingSeenCount": 0,
            "hasClaudeMdExternalIncludesApproved": false,
            "hasClaudeMdExternalIncludesWarningShown": false,
        ]
    }

    /// Set `projects[cwd].hasTrustDialogAccepted` to true.
    ///
    /// Creates the file, or a minimal project entry, when either is missing.
    /// An entry that is already accepted is not rewritten. Every other key is
    /// kept. A file that is not a JSON object — or a `projects` value / project
    /// entry that is not an object — is left byte for byte, so a bad read cannot
    /// replace the user's config. Returns whether the cwd is trusted afterwards.
    @discardableResult
    public static func ensureAccepted(cwd: String, claudeConfigURL: URL) -> Bool {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let key = projectKey(for: trimmed)
        guard !key.isEmpty else { return false }

        guard FileManager.default.fileExists(atPath: claudeConfigURL.path) else {
            return write(["projects": [key: newProjectEntry()]], to: claudeConfigURL)
        }
        guard let data = try? Data(contentsOf: claudeConfigURL),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              var root = parsed as? [String: Any] else { return false }

        var projects: [String: Any]
        if root["projects"] == nil {
            projects = [:]
        } else if let map = root["projects"] as? [String: Any] {
            projects = map
        } else {
            return false
        }

        if let existing = projects[key] {
            guard var entry = existing as? [String: Any] else { return false }
            if (entry["hasTrustDialogAccepted"] as? Bool) == true { return true }
            entry["hasTrustDialogAccepted"] = true
            projects[key] = entry
        } else {
            projects[key] = newProjectEntry()
        }
        root["projects"] = projects
        return write(root, to: claudeConfigURL)
    }

    /// Replace `url` with `root`. Pretty-printed so a hand-edited config stays
    /// readable; the rename is atomic and the file is `0600` (the config holds
    /// Claude account state).
    private static func write(_ root: [String: Any], to url: URL) -> Bool {
        guard JSONSerialization.isValidJSONObject(root),
              var data = try? JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return false }
        if data.last != 0x0A { data.append(0x0A) }
        do {
            try PrivateFile.write(data, to: url)
            return true
        } catch {
            return false
        }
    }
}
