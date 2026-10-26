import Foundation

/// On-disk locations Admiral owns under Application Support, computed identically by the
/// app and the `admiral-hook` helper (two different processes) so both agree on a session's
/// per-session directory. `base` is injected so tests can use a temp dir.
public enum AdmiralPaths {
    /// Isolation seam: tests (and profiled probe instances) export ADMIRAL_SUPPORT_DIR so
    /// hooks.json / session dirs never touch the real support dir. getenv (not a cached
    /// ProcessInfo snapshot) so tests can set/unset around assertions. Nil for the real install.
    public static var supportDirOverride: URL? {
        guard let raw = getenv("ADMIRAL_SUPPORT_DIR") else { return nil }
        let path = String(cString: raw)
        return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
    }

    /// `~/Library/Application Support/Admiral` (created if missing).
    public static var defaultSupportDir: URL {
        if let dir = supportDirOverride {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Admiral", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `<base>/sessions/<token>` (created if missing). The token arrives as `ADMIRAL_SESSION`
    /// in the hook helper's environment, so it is `sanitized` like a payload session id and
    /// can never name a directory outside `sessions/`.
    public static func sessionDir(base: URL, token: String) -> URL {
        let dir = base.appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(sanitized(token), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The per-session append-log of write events.
    public static func touchedLog(base: URL, token: String) -> URL {
        sessionDir(base: base, token: token).appendingPathComponent("touched.jsonl")
    }

    /// The per-session append-log of user prompts (watchdog trigger detection).
    public static func promptsLog(base: URL, token: String) -> URL {
        sessionDir(base: base, token: token).appendingPathComponent("prompts.jsonl")
    }

    /// The per-session settings file injected via `--settings`.
    public static func settingsFile(base: URL, token: String) -> URL {
        sessionDir(base: base, token: token).appendingPathComponent("settings.json")
    }

    /// Present while the bundled `admiral` mod should write a PHI-redacted copy of each output
    /// round (Settings → Bridge & API). The mod checks it at every turn end (path handed over as
    /// `ADMIRAL_REDACT_FLAG`), so creating or removing it reaches a running session at once.
    public static func redactRepliesFlag(base: URL, token: String) -> URL {
        sessionDir(base: base, token: token).appendingPathComponent("redact-replies")
    }

    /// Where the mod writes those copies, one `output-<round>.json` per finished round of the
    /// tab's output schema (`ADMIRAL_REDACTED_DIR`); the SSE feed's `output` events come from
    /// them while the flag is set.
    public static func redactedOutputDir(base: URL, token: String) -> URL {
        sessionDir(base: base, token: token).appendingPathComponent("redacted-output", isDirectory: true)
    }

    /// The per-session MCP config injected via `--mcp-config` (registers Admiral's own bridge).
    public static func mcpConfigFile(base: URL, token: String) -> URL {
        sessionDir(base: base, token: token).appendingPathComponent("bridge-mcp.json")
    }

    /// Present for an API tool tab (commissioned from `POST /v1/messages` with `tools[]`).
    /// The hook helper reads it to deny built-ins and to inject the client-tool catalog.
    public static func clientToolModeFile(base: URL, token: String) -> URL {
        sessionDir(base: base, token: token).appendingPathComponent("client-tool-mode")
    }

    /// The client's `tools[]` for that tab. The `client` MCP process serves `tools/list`
    /// from this file and watches its mtime for `notifications/tools/list_changed`.
    public static func clientToolsFile(base: URL, token: String) -> URL {
        sessionDir(base: base, token: token).appendingPathComponent("client-tools.json")
    }


    /// The per-session structured-output tripwire — armed by the Anthropic endpoint,
    /// read by the Stop hook (helper process) and the `set_structured_output` bridge
    /// tool, cleared by the endpoint when its request finishes.
    public static func structuredOutputFile(base: URL, token: String) -> URL {
        sessionDir(base: base, token: token).appendingPathComponent("structured-output.json")
    }

    /// `<base>/goals/<session>.json` — a session's goals.
    ///
    /// Keyed by the claude session id rather than `ADMIRAL_SESSION`, for two reasons: the
    /// token is a fresh UUID every launch (goals would orphan on restart), and the hook
    /// helper — a different process — only learns the session id, from the hook payload.
    /// Both writers agree on this one path, so the panel and the prompt reminder can never
    /// disagree about what is still open.
    public static func goalsFile(base: URL, session: String) -> URL {
        let dir = base.appendingPathComponent("goals", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(sanitized(session)).json")
    }

    /// The goals context the session was last sent, beside its goals file. The prompt reminder
    /// compares against it so an unchanged reminder is not re-sent into context every prompt.
    public static func goalsRemindedFile(base: URL, session: String) -> URL {
        goalsFile(base: base, session: session).deletingPathExtension().appendingPathExtension("reminded")
    }

    /// `<base>/groups/` — group chats: `groups.json`, a `<group>.jsonl` log and a
    /// `<group>.cursors.json` per group. Read by the app and by the `admiral-hook` helper
    /// (which prepends a member's unseen messages), so it is plain files like goals.
    public static func groupsDir(base: URL) -> URL {
        let dir = base.appendingPathComponent("groups", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: Int(PrivateFile.directoryMode)])
        return dir
    }

    public static func groupsFile(base: URL) -> URL {
        groupsDir(base: base).appendingPathComponent("groups.json")
    }

    public static func groupLogFile(base: URL, group: UUID) -> URL {
        groupsDir(base: base).appendingPathComponent("\(group.uuidString).jsonl")
    }

    public static func groupCursorsFile(base: URL, group: UUID) -> URL {
        groupsDir(base: base).appendingPathComponent("\(group.uuidString).cursors.json")
    }

    /// `<base>/groups/sidebar-order.json` — `[UUID]`: tabs (by `AgentSession.stableKey`) and
    /// groups, in the order the sidebar shows them.
    public static func sidebarOrderFile(base: URL) -> URL {
        groupsDir(base: base).appendingPathComponent("sidebar-order.json")
    }

    /// `{memberKey: callsign}`, written by the app (`GroupService.writeCallsigns`). Member keys
    /// are claude session ids, so the hook needs no other index — only the names.
    public static func groupCallsignsFile(base: URL) -> URL {
        groupsDir(base: base).appendingPathComponent("callsigns.json")
    }

    /// The membership lines a session was last sent by the prompt hook, like
    /// `goalsRemindedFile`: re-sent only when they change, forgotten on clear/compact.
    public static func groupMembershipSentFile(base: URL, session: String) -> URL {
        groupsDir(base: base).appendingPathComponent("\(sanitized(session)).membership")
    }

    /// `<base>/output-schema/<session>.json` — the JSON schema every turn of this session must
    /// answer (`output` slot). Keyed by the claude session id, like goals, so a reload, a
    /// restore and a relaunch keep it.
    public static func outputSchemaFile(base: URL, session: String) -> URL {
        let dir = base.appendingPathComponent("output-schema", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(sanitized(session)).json")
    }

    /// `<base>/pr-watch/<session>.json` — what a session has been told about its PRs.
    ///
    /// Same keying as `goalsFile`, and for the same reason: this file IS the "don't say it
    /// twice" guard, so it has to outlive both an app relaunch and a `--resume`.
    public static func prWatchFile(base: URL, session: String) -> URL {
        let dir = base.appendingPathComponent("pr-watch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(sanitized(session)).json")
    }

    /// `<base>/hooks/fired/<session>.jsonl` — the once-per-session rule ledger.
    ///
    /// Deliberately **not** under `sessions/<token>/`: it is keyed by the hook payload's
    /// `session_id`, not by `ADMIRAL_SESSION`, so it survives `SessionManager.delete` and
    /// works for a session Admiral never launched.
    public static func firedLog(base: URL, session: String) -> URL {
        let dir = base.appendingPathComponent("hooks", isDirectory: true)
            .appendingPathComponent("fired", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(sanitized(session)).jsonl")
    }

    /// The authored hooks + shared policy (read by the app and the helper).
    public static func hooksFile(base: URL) -> URL {
        base.appendingPathComponent("hooks.json")
    }

    /// A session id arrives from an untrusted payload (and a token from the environment);
    /// anything outside a safe alphabet becomes `_`, and a name of dots alone (`.`, `..`)
    /// becomes `_`, so it is always one plain path component that cannot traverse out of the
    /// directory. A UUID passes through unchanged.
    public static func sanitized(_ component: String) -> String {
        let safe = String(component.map { character in
            character.isASCII && (character.isLetter || character.isNumber) || "._-".contains(character)
                ? character : "_"
        })
        return safe.allSatisfy({ $0 == "." }) ? "_" : safe
    }
}
