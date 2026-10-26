import Foundation

/// Builds the per-session `settings.json` Admiral injects via `--settings`, exactly as it
/// injects `--mcp-config` for the bridge relay. It contains a top-level `hooks` block, so
/// it merges non-destructively: `--settings` overrides only the keys it names, and hooks union
/// across settings sources. A normal tab leaves the user's `permissions` untouched. An API
/// tool tab also writes `permissions` (`bypassPermissions` plus a built-in deny list) so a
/// parked tool call is not a dialog the HTTP client cannot answer.
///
/// **This is no longer a governance mechanism.** Governance lives in `hookd`, registered
/// globally. Admiral injects these events because each of its own features below is
/// delivered by a hook and by nothing else:
///
/// | event | why |
/// |---|---|
/// | `PostToolUse` | records touched repos into `sessions/<token>/touched.jsonl` |
/// | `Stop` | consults the structured-output tripwire (`set_structured_output`) |
/// | `UserPromptSubmit` | records the prompt the session watchdog reads for triggers, and the chat ledger's prompts |
/// | `Notification` | chat ledger: claude is blocked on a permission prompt |
/// | `PreToolUse` | denies `AskUserQuestion` while the tab shows Chat (matcher on). An API tool tab matches every tool and denies anything that is not `mcp__client__*` |
/// | `SessionStart` | after `/clear` or compaction, the goals reminder is sent in full again |
///
/// On a normal tab `PreToolUse` is matched to `AskUserQuestion`, so no other tool call pays
/// for a hook process. An API tool tab drops that matcher. `SessionStart` is matched to
/// `clear|compact`, the two sources that drop context; `PostToolUse` filters by tool
/// internally, and the rest take none.
public enum HookSettings {
    /// The events Admiral still needs delivered. Adding one means a new Admiral feature
    /// that needs a hook — not governance, which lives elsewhere now.
    static let injectedEvents = ["PostToolUse", "Stop", "UserPromptSubmit", "Notification", "PreToolUse",
                                 "SessionStart"]

    /// Events registered for some tools (or sources) only.
    static let matchers = ["PreToolUse": "AskUserQuestion", "SessionStart": "clear|compact"]

    /// `providerEnv` is a CC Switch provider's environment (base URL, auth token, model
    /// names). It rides here rather than in the process environment for two reasons: a
    /// `--settings` file is claude's highest-precedence settings source, so the session
    /// reaches that provider even when `~/.claude/settings.json` names another one; and the
    /// auth token stays out of `ps eww`. Nil (the default) is a stock Anthropic session,
    /// which carries no `env` block at all.
    ///
    /// `acceptPeerMessages` adds `crossSessionInbound: "accept"`. An explicit value is the
    /// only thing that lifts claude's hold on socket messages to a `bypassPermissions`
    /// session, and this file's source outranks the user's own settings.
    /// `clientTools` is an API tool tab. Its `PreToolUse` hook matches every tool (the
    /// AskUserQuestion matcher would never see Bash), and `permissions` denies built-ins
    /// and forces `bypassPermissions`. A normal tab stays hooks-only.
    public static func json(helper: String, providerEnv: [String: String]? = nil,
                            acceptPeerMessages: Bool = false, clientTools: Bool = false) -> [String: Any] {
        var matchers = matchers
        if clientTools { matchers.removeValue(forKey: "PreToolUse") }
        func entry(_ event: String) -> [String: Any] {
            var entry: [String: Any] = ["hooks": [["type": "command", "command": command(helper: helper, event: event)]]]
            if let matcher = matchers[event] { entry["matcher"] = matcher }
            return entry
        }

        var hooks: [String: Any] = [:]
        for event in injectedEvents { hooks[event] = [entry(event)] }
        var settings: [String: Any] = ["hooks": hooks]
        if let providerEnv, !providerEnv.isEmpty { settings["env"] = providerEnv }
        if acceptPeerMessages { settings["crossSessionInbound"] = "accept" }
        if clientTools {
            settings["permissions"] = [
                "defaultMode": "bypassPermissions",
                "deny": ClientToolGuard.builtInDenyList,
            ]
        }
        return settings
    }

    /// Single-quoted so a bundle path with spaces is safe.
    static func command(helper: String, event: String) -> String {
        "\(ShellQuote.single(helper)) claude \(event)"
    }

    /// Writes the hooks-only settings to `url`. Returns true only if the file was actually
    /// written — so the caller can DECLINE to inject `--settings` on failure rather than point
    /// claude at a missing file (which would refuse to launch). The hook is best-effort: a
    /// write failure must degrade to "no hook," never break the session.
    @discardableResult
    public static func write(helper: String, providerEnv: [String: String]? = nil,
                             acceptPeerMessages: Bool = false, clientTools: Bool = false,
                             to url: URL) -> Bool {
        guard let data = try? JSONSerialization.data(
            withJSONObject: json(helper: helper, providerEnv: providerEnv,
                                 acceptPeerMessages: acceptPeerMessages, clientTools: clientTools),
            options: .withoutEscapingSlashes
        ) else { return false }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // The file can hold a provider's API token, so it is the session's to read and
        // nobody else's — 0600 from its first byte, never world-readable in between.
        do { try PrivateFile.write(data, to: url) } catch { return false }
        return true
    }
}
