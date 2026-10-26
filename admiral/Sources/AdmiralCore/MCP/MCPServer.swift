import Foundation

/// Who is calling the MCP server. Set by the TRANSPORT, never read from the request: the
/// bridge socket is always `.session` (whatever its envelope's token says — a token of
/// `admiral-operator` there is just a token that names no tab), and only the operator HTTP
/// endpoint passes `.operator`.
public enum MCPCaller: Sendable, Equatable {
    /// The operator: `POST /mcp`, or Admiral itself (probes).
    case `operator`
    /// A hosted tab, named by its `ADMIRAL_SESSION` token.
    case session(String)

    /// The token `BridgeCore` resolves the caller by. The operator's names no tab, so tools
    /// that need a sender (hail, set_goal_self, …) fail for it as they always have.
    var bridgeToken: String {
        switch self {
        case .operator: return OperatorTokenStore.mcpSessionToken
        case let .session(token): return token
        }
    }
}

/// Minimal MCP JSON-RPC dispatcher over `BridgeCore`. Handles `initialize`,
/// `tools/list`, and `tools/call` for a caller the transport identified (`MCPCaller`).
@MainActor
public struct MCPServer {
    private let bridge: BridgeCore
    public init(bridge: BridgeCore) { self.bridge = bridge }

    /// Tools only the operator may call: they act on any tab with no sender identity (typing
    /// into it, reading its screen or transcript, closing it). A session caller is refused
    /// them and never sees them in `tools/list`.
    public static let operatorTools: Set<String> = [
        "inject", "send_keys", "read_screen", "read_recent", "close_session", "commission_bash",
        "list_sessions", "session_status", "focus", "fleet_pr_status",
    ]

    /// Tool definitions exposed to MCP clients, carrying the built-in goal guidance. The
    /// live list is `tools(guidance:)` — a session gets whatever `goal-guidance.txt` says.
    public static let tools: [[String: Any]] = tools(guidance: GoalGuidance.builtIn + " "
                                                     + GoalGuidance.limits)

    /// The bridge tools. `guidance` is spliced into both `set_goal` descriptions because a
    /// caller only ever reads the description of the one it invokes. `groups` adds the
    /// `group_*` tools (only while `features.groups` is on — `bridge.groups != nil`).
    public static func tools(guidance goalWritingGuidance: String, groups: Bool = false) -> [[String: Any]] {
        baseTools(guidance: goalWritingGuidance) + (groups ? groupTools : [])
    }

    /// The `group_*` tools. Listed only when groups are on; `call` refuses them otherwise.
    static let groupTools: [[String: Any]] = [
        tool("group_say",
             "Post a message to a group chat you are a member of, as yourself. Use it to answer "
             + "a [group \"…\"] prompt or to tell the group something it needs. `@name` / `@all` "
             + "in `text`, and the callsigns in `to`, tag members: tagged members are woken, "
             + "untagged posts wake every idle member but you. Send exactly `[pass]` to say "
             + "nothing (not logged). Fails if the group is unknown, you are not a member, or a "
             + "name in `to` is not a member (the error lists who is). If all you would say is "
             + "an acknowledgement (got it, thanks, agreed, done), do NOT post it: use "
             + "group_react on that message instead.",
             ["group": "string", "text": "string", "to": "string[]?"]),
        tool("group_react",
             "React to a group message with 👀 (seen, looking into it), 👍 (agree / ok), 👎 "
             + "(disagree / no) or ✅ (done) instead of sending a message, whenever an "
             + "acknowledgement is all you have to say. `message` is the #id at the start of "
             + "the message's line in the group prompt or group_log (\"#12 @api: …\" → 12). A "
             + "reaction is shown on that message and read by the group, wakes nobody and "
             + "costs no message budget; it counts as your answer to the prompt, so end the turn "
             + "with exactly [pass]. React with group_say instead when you owe an answer or "
             + "new information. Fails for an unknown group or message, a group you are not in, "
             + "your own message, a message that is itself a reaction, or any other emoji.",
             ["group": "string", "message": "integer", "emoji": "string"]),
        tool("group_log",
             "Read a group's message log (groups you are a member of only), one `#id @author: "
             + "text` line each; the #id is what group_react takes. Use it when a group prompt "
             + "says earlier messages were left out, or to catch up. `since` returns messages "
             + "after that id, oldest first; without it, the newest ones. `limit` caps the "
             + "count (default 50). Reactions appear as lines too (\"reacted 👍 to #5\"); they "
             + "need no reply. Fails for an unknown group or one you are not in.",
             ["group": "string", "since": "integer?", "limit": "integer?"]),
        tool("group_list",
             "List the group chats you are a member of: name, each member's callsign and state "
             + "(idle/busy/shell), and whether the group is paused (agents used their message "
             + "budget; it resumes when the user writes). To acknowledge a message in one of "
             + "them without posting, use group_react. No arguments.",
             [:]),
        tool("group_create",
             "Create a group chat of existing tabs, named by callsign. You are NOT added unless "
             + "you list yourself. Use it when the user asks for several sessions to work "
             + "something out together. Fails with fewer than 2 members, an unknown callsign "
             + "(the error lists the tabs), or a name already taken.",
             ["name": "string", "members": "string[]"]),
        tool("group_add_member",
             "Add a tab (by callsign) to a group chat you are a member of. Fails for an unknown "
             + "group or callsign, a group you are not in, or a tab already in it.",
             ["group": "string", "member": "string"]),
        tool("group_remove_member",
             "Remove a tab (by callsign) from a group chat you are a member of; the tab itself "
             + "stays open. Refused when it would leave fewer than 2 members — delete the group "
             + "instead. Fails for an unknown group, a group you are not in, an unknown "
             + "callsign, or a tab not in it.",
             ["group": "string", "member": "string"]),
        tool("group_rename",
             "Rename a group chat you are a member of. Fails for an unknown group, a group you "
             + "are not in, an empty name, or a name another group already has.",
             ["group": "string", "name": "string"]),
        tool("group_delete",
             "Delete a group chat you are a member of. Its tabs stay open and nothing is sent to "
             + "them; its message log is removed from Admiral but the transcript copy under the "
             + "claude folder's groups/ is kept. Only do this when the user asked for it. Fails "
             + "for an unknown group or one you are not in.",
             ["group": "string"]),
    ]

    private static func baseTools(guidance goalWritingGuidance: String) -> [[String: Any]] { [
        tool("callsign",
             "Return YOUR own station callsign (the tab name peers use to hail you). "
             + "Use this when you are unsure what name you appear as on the roster, or before "
             + "telling another station how to address you. No arguments. Fails only if your "
             + "session token is unknown (Admiral not wired).",
             [:]),
        tool("notify",
             "Show a native macOS notification for YOUR tab: use it when you need the user's "
             + "attention (a decision, a finished long task, a blocker) and they may be in "
             + "another app or tab. Clicking it brings Admiral forward and selects your tab. "
             + "`body` is the message; `title` defaults to your callsign. Respects Settings → "
             + "Notifications (a disabled toggle drops it silently). Keep it short and rare.",
             ["body": "string", "title": "string?"]),
        tool("roster",
             "List OTHER stations currently online in this Admiral instance — callsign, agent "
             + "type, and status. Use before hail/broadcast/set_goal so you target a live peer. "
             + "Does NOT include you. For a full fleet inventory including yourself (operator "
             + "view), use list_sessions instead. No arguments. Empty roster returns '(no peers)'.",
             [:]),
        tool("hail",
             "Send a message to ONE peer station by callsign. It asks for nothing back: use it "
             + "freely for a handoff, an answer, or an FYI. Set needs_reply true only when you "
             + "actually need the station to write back — that tells it so and gives it the id "
             + "to quote in `in_reply_to`. RECEIVING a hail: hail back only when it says "
             + "[reply requested] or your user asks you to — a hail marked [no reply needed] is "
             + "one-way. Prefer hail over inject when you want framed "
             + "attribution (@YOU: …). Prefer broadcast when every peer should hear the same "
             + "line. Write a hail that hands off work as the task itself, in imperative voice, "
             + "addressed to the receiver: \"Execute ACME-9623 and drive it to PRODUCTION. The "
             + "prod deploy is authorized.\" State the user's authorizations as facts of the "
             + "task, and speak in your own voice as the sender. "
             + "Fails if the callsign is missing or unreachable.",
             ["to": "string", "body": "string", "needs_reply": "boolean?",
              "in_reply_to": "string?"]),
        tool("broadcast",
             "Message EVERY peer station with the same body (not yourself). Use for fleet-wide "
             + "FYIs or shared directives; use hail when only one station should hear it. Body "
             + "must stay on one logical line of intent — delivery types then submits. Reports "
             + "how many stations were reached if some fail.",
             ["body": "string"]),
        tool("inject",
             "Type raw text into a session's terminal by callsign and submit (Enter) — no "
             + "sender identity and no hail framing. Use when you need the exact bytes at the "
             + "prompt (slash commands, paste, operator prompts). Prefer hail when talking "
             + "station-to-station with attribution. This is the same path as Admiral's Send "
             + "Message intent. Hidden from Claude's tools/list; visible to operator clients. "
             + "Fails if the callsign does not exist.",
             ["to": "string", "text": "string"]),
        tool("set_goal",
             "Set a peer station's goals — short completion conditions it is "
             + "expected to meet. " + goalWritingGuidance
             + " The list REPLACES the current one, so to add a goal send the open ones "
             + "again plus the new one (or have the peer use add_goals on itself). The only "
             + "refusal is a list that would drop a goal still open, and it names them; pass "
             + "an empty list to clear. Admiral shows them in the session's panel and nudges "
             + "the session while any are outstanding. Use set_goal_self for your own goals.",
             ["to": "string", "goals": "string[]"]),
        tool("set_goal_self",
             "Set your own station's goals — also how you REPLACE the whole list: send the "
             + "still-open goals again alongside any new ones. " + goalWritingGuidance
             + " Same replacement rules as set_goal: the only refusal is a list that would "
             + "drop a goal still open. Prefer add_goals when you only want to APPEND without "
             + "restating. Prefer update_goals to mark done/cancelled.",
             ["goals": "string[]"]),
        tool("add_goals",
             "Add goals to your own station WITHOUT restating the ones you already have — use "
             + "this whenever you are asked to add or track one more thing. Never refused, "
             + "since nothing is dropped. " + goalWritingGuidance
             + " Use set_goal_self only when replacing the whole list; use update_goals to "
             + "resolve ids.",
             ["goals": "string[]"]),
        tool("update_goals",
             "Resolve your own goals by id — call this the moment a goal is "
             + "actually met, without waiting to be asked. Pass ids in `done` (achieved), "
             + "`cancelled` (no longer applies — it leaves the panel), or `open` (reopen "
             + "one). Ids look like g1, g2 and are shown in the reminder you get with each "
             + "prompt. Setting a new goal list refuses while any goal is still open, so "
             + "resolve them here first. Pass whichever lists apply — cancelling some goals "
             + "takes no `done`. Name at least one id or the call fails.",
             ["done": "string[]?", "cancelled": "string[]?", "open": "string[]?"]),
        askUserQuestionTool,
        tool("pr_status",
             "What Admiral last saw of the pull requests on the repos YOU have written to: "
             + "merge state (blocked/mergeable/merged), checks, approvals, and how long ago "
             + "it was checked. You are told automatically when any of that changes — call "
             + "this only when you want the picture right now. Watching runs while this "
             + "session's watchdog is armed. For every session's PRs (operator), use "
             + "fleet_pr_status instead. Fails if nothing has been recorded yet.",
             [:]),
        tool("commission",
             "Launch a NEW Claude Code session in Admiral. `cwd` is required and must be an "
             + "existing directory — the session never silently lands in a default folder. "
             + "`callsign` becomes the tab name / hail address (spaces become hyphens). "
             + "Optional `provider`: a CC Switch provider id or exact name (e.g. "
             + "'GLM5.3 via Fireworks AI') so the tab uses that custom model instead of "
             + "stock Anthropic. Omit `provider` for stock. Unknown provider names fail. "
             + "Use commission_bash for a plain zsh tab with no claude. "
             + "Optional `scratch`: true makes it a scratch tab — a small row at the bottom of "
             + "the sidebar, not restored on relaunch, and closed automatically once it sits "
             + "idle with no open goals; the user can promote it to a permanent tab. Omit "
             + "`scratch` to follow the user's setting. "
             + "`output_schema` is OPTIONAL and rarely wanted: leave it out unless the user "
             + "explicitly asked for the tab to return structured output. When given, it is a "
             + "strict JSON Schema (as a JSON string) that EVERY turn of the tab must answer with "
             + "set_structured_output(type: \"output\") before it can end — root `type: object`, "
             + "every object with `additionalProperties: false` and all its properties in "
             + "`required`, keywords limited to type/properties/required/items/enum/const/"
             + "additionalProperties/description/title. A non-strict schema fails the call. "
             + "Returns the new session id prefix on success.",
             ["callsign": "string", "cwd": "string", "provider": "string?", "scratch": "boolean?",
              "output_schema": "string?"]),
        tool("set_output_schema",
             "Set, replace or clear a Claude tab's output schema by callsign — a session may "
             + "name only its own tab; the operator any tab. Use it "
             + "ONLY when the user explicitly asks for a tab to return structured output — it "
             + "is optional and changes how every turn of that tab ends. With a "
             + "schema (strict JSON Schema as a JSON string, same rules as commission's "
             + "`output_schema`), every turn of that tab from its next prompt must end with "
             + "set_structured_output(type: \"output\"); each turn's result shows in "
             + "session_status and the tab's event stream. Pass an empty `schema` to clear it. "
             + "Fails for a missing callsign, a bash tab, or a non-strict schema (every reason "
             + "is listed).",
             ["callsign": "string", "schema": "string"]),
        tool("rename_station",
             "Rename YOUR station. Renames BOTH the tab and the claude inside "
             + "it, so the name you hail by and the name it answers to cannot drift apart. "
             + "Spaces become hyphens — the name is also the address. `to` names the tab to "
             + "rename and is for the operator: a session may rename only itself, and another "
             + "tab's callsign is refused. No-op if already "
             + "that name; fails if empty after sanitize or target missing.",
             ["name": "string", "to": "string?"]),
        tool("set_structured_output",
             "Deliver this turn's final answer as structured "
             + "output. Pass `output` as a JSON string matching the schema you were "
             + "given, and `type` to say which request you are answering (the Stop "
             + "instruction names it) — `type` is only required when more than one is "
             + "armed at once. Only meaningful when a structured-output request armed "
             + "your session — otherwise it reports that nothing is armed. One exception: "
             + "while a watchdog is watching you, you may report to it at any time, "
             + "unasked, with `{\"status\":\"done\"|\"blocked\"|\"in_progress\",\"reason\":…}` "
             + "— do so when the user tells you the work is done or to close it, since "
             + "\"done\" is what stops the watchdog. A tab created with an output schema "
             + "owes `type: \"output\"` every turn. On schema failure you may retry until "
             + "attempts are exhausted.",
             ["output": "string", "type": "string?"]),
        tool("list_sessions",
             "OPERATOR: list EVERY session Admiral is hosting — callsign, agent type "
             + "(claude_code|bash), status, cwd, and git branch when known. Includes you and "
             + "bash tabs. Use this to pick a target before inject/focus/close_session/"
             + "read_recent. Prefer roster when you are a station that only needs peer "
             + "callsigns. No arguments. Returns '(no sessions)' if the fleet is empty.",
             [:]),
        tool("session_status",
             "OPERATOR: detailed status for ONE session by callsign — idle/busy, agent type, "
             + "cwd, branch, last activity age, plan progress (if any), and open goals. Use "
             + "after list_sessions when deciding whether to inject or wait. Fails if the "
             + "callsign does not exist.",
             ["callsign": "string"]),
        tool("focus",
             "OPERATOR: select a session in Admiral's UI by callsign (sets the selected tab). "
             + "Does not by itself guarantee the app window is frontmost — that is an App "
             + "layer concern. Use before the human needs to look at that tab. Fails if the "
             + "callsign is missing.",
             ["callsign": "string"]),
        tool("close_session",
             "OPERATOR / DESTRUCTIVE: permanently close and tear down a session by callsign "
             + "(same as sidebar delete). The PTY and session state are gone; there is no "
             + "undo. Confirm with the user before calling unless they explicitly ordered "
             + "the close. Fails if the callsign is missing.",
             ["callsign": "string"]),
        tool("read_recent",
             "OPERATOR: return the last N transcript turns (messages) for a session by "
             + "callsign — full USER / ASSISTANT / THINKING / TOOL bodies with newlines "
             + "preserved and no character truncation. `limit` is the turn count (default "
             + "20, hard cap 100), not a byte/char budget. Use before inject so you are "
             + "not flying blind, or to report what a session just did. Returns "
             + "'(no transcript yet)' for bash tabs or brand-new sessions. Fails if the "
             + "callsign is missing.",
             ["callsign": "string", "limit": "string?"]),
        tool("read_screen",
             "OPERATOR: return exactly what is visible in a session's terminal viewport "
             + "(live SwiftTerm buffer — works for bash and Claude tabs). Not the Claude "
             + "transcript; use read_recent for that. One line per row, right-trimmed. "
             + "Fails if the callsign is missing or has no live PTY.",
             ["callsign": "string"]),
        tool("send_keys",
             "OPERATOR: send key input to a session as raw PTY bytes with NO trailing Enter "
             + "(piloting TUIs: k9s, vim, less, …). Separate from inject, which types text "
             + "then submits. "
             + "HOW TO USE — `keys` is one chord or a comma-separated sequence. "
             + "Named conveniences: left/right/up/down, enter, escape, tab, backspace, "
             + "delete, insert, home, end, pageup/pagedown, space, f1…f24 (and beyond). "
             + "Modifiers prefix with +: shift+left, ctrl+c, alt+enter, ctrl+shift+right. "
             + "ANYTHING ELSE IS ALLOWED — there is no allowlist that rejects keys. "
             + "(1) literal characters: keys=xyz or shift+o. "
             + "(2) raw bytes: keys='raw:\\e[1;5A' (\\e=ESC; also \\n \\r \\t \\xHH). "
             + "(3) hex bytes: keys=hex:1b5b41. "
             + "When unsure what a TUI expects, call read_screen, try a named chord, or paste "
             + "the exact escape as raw:. Fails only on empty keys, missing callsign, or bad hex.",
             ["callsign": "string", "keys": "string"]),
        tool("commission_bash",
             "OPERATOR: launch a plain interactive login zsh tab (no Claude Code, no "
             + "transcript/hooks/restore) — same as Admiral's New Bash. `cwd` must be an "
             + "existing directory; `callsign` names the tab. Optional `scratch`: same as "
             + "commission's. Use commission for a Claude Code session instead.",
             ["callsign": "string", "cwd": "string", "scratch": "boolean?"]),
        tool("fleet_pr_status",
             "OPERATOR: PR watch snapshot across ALL managed Claude sessions that have "
             + "recorded state — merge/checks/approvals and age, grouped by callsign. Reads "
             + "the on-disk watch cache (no live `gh` call). Use pr_status when a station "
             + "only needs its own repos. Returns a clear empty message when no session has "
             + "watch data (watchdog must have been armed).",
             [:]),
        tool("schedule_list",
             "List every schedule: its name (also the name of the tab each run opens), its cron "
             + "and what it means, the next run, the folder, scratch or regular tab, its custom "
             + "model and output schema if any, and how the last run went. No arguments.",
             [:]),
        tool("schedule_set",
             "Create a schedule, or update the one called `name`. On its cron Admiral opens a NEW "
             + "tab named after the schedule in `cwd` and types `prompt` into it. Creating needs "
             + "`cron` (five fields in the Mac's local time, or @hourly/@daily/@weekly/@monthly/"
             + "@yearly), `cwd` (an existing folder) and `prompt`; an update changes only what you "
             + "pass. `name` follows the tab-name rule (spaces become hyphens) and must be unique; "
             + "`new_name` renames, keeping the history. `scratch` (default true) opens scratch "
             + "tabs. `model` is the claude model every run launches with — sonnet, haiku, opus "
             + "or fable (default opus); `effort` is its effort level — low, medium, high, xhigh "
             + "or max (empty leaves claude's own default). `provider` runs it on a custom model — "
             + "a CC Switch provider id or exact name; an empty string goes back to stock "
             + "Anthropic. `output_schema` is OPTIONAL and "
             + "rarely wanted: leave it out unless the user asked for structured output — a strict "
             + "JSON Schema (same rules as commission's) each run's turn must answer with. "
             + "`enabled` false pauses it. Answers with the next three run times; every problem "
             + "is listed.",
             ["name": "string", "new_name": "string?", "cron": "string?", "cwd": "string?",
              "prompt": "string?", "scratch": "boolean?", "model": "string?", "effort": "string?",
              "provider": "string?", "output_schema": "string?", "enabled": "boolean?"]),
        tool("schedule_delete",
             "Delete the schedule called `name` and its run history. Tabs its runs opened stay open.",
             ["name": "string"]),
        tool("schedule_run",
             "Run the schedule called `name` now: open its tab and type its prompt, without waiting "
             + "for the turn to finish. Skipped while its previous run is still going. Returns the "
             + "run id and the tab; follow it with schedule_history.",
             ["name": "string"]),
        tool("schedule_history",
             "Schedule runs, newest first: run id, schedule, status (running, succeeded, failed, "
             + "timedOut, skipped, missed), trigger (cron, now, late), times, tab and claude "
             + "session id. `name` limits it to one schedule; `limit` caps the count (default 20). "
             + "With `run_id`, that one run plus its reply and structured output, read from its "
             + "session's transcript.",
             ["name": "string?", "run_id": "string?", "limit": "string?"]),
    ] }

    /// Transport envelope: `{"token": "<session>", "request": <jsonrpc>}`. The bridge socket
    /// reads one line and calls this; the token carries the caller's `ADMIRAL_SESSION`, the
    /// request is a normal JSON-RPC message. Always a SESSION caller — the socket has no
    /// operator credential, so no token can make it one.
    public func handle(envelope data: Data) -> Data {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["token"] as? String,
              let request = obj["request"],
              let reqData = try? JSONSerialization.data(withJSONObject: request)
        else { return Self.error(id: nil, code: -32700, message: "parse error") }
        return handle(requestData: reqData, caller: .session(token))
    }

    /// A session caller's request (`.session(sessionToken)`).
    public func handle(requestData: Data, sessionToken: String) -> Data {
        handle(requestData: requestData, caller: .session(sessionToken))
    }

    public func handle(requestData: Data, caller: MCPCaller) -> Data {
        guard let obj = try? JSONSerialization.jsonObject(with: requestData) as? [String: Any] else {
            return Self.error(id: nil, code: -32700, message: "parse error")
        }
        let id = obj["id"]
        // A request without an `id` is a JSON-RPC notification: never respond.
        if id == nil { return Data() }
        guard let method = obj["method"] as? String else {
            return Self.error(id: id, code: -32600, message: "invalid request")
        }
        switch method {
        case "initialize":
            return Self.result(id: id, value: [
                "protocolVersion": "2024-11-05",
                "serverInfo": ["name": "admiral", "version": "1.0"],
                "capabilities": ["tools": [String: Any]()],
                "instructions": NudgeInstructions.text(groups: bridge.groups != nil),
            ])
        case "tools/list":
            // Read the guidance file here rather than at load: this is the one moment a
            // session's tool descriptions are decided, so an edit reaches every session
            // started after it without the app restarting.
            var tools = Self.tools(guidance: GoalGuidance.text(base: bridge.supportDir),
                                   groups: bridge.groups != nil)
            if caller != .operator {
                tools.removeAll { Self.operatorTools.contains($0["name"] as? String ?? "") }
            }
            return Self.result(id: id, value: ["tools": tools])
        case "tools/call":
            let params = obj["params"] as? [String: Any] ?? [:]
            guard let name = params["name"] as? String, !name.isEmpty else {
                return Self.error(id: id, code: -32602, message: "invalid params: missing tool name")
            }
            let args = params["arguments"] as? [String: Any] ?? [:]
            let outcome = refusal(of: name, args: args, for: caller)
                ?? call(name: name, args: args, token: caller.bridgeToken)
            return Self.result(id: id, value: [
                "content": [["type": "text", "text": outcome.message]],
                "isError": !outcome.ok,
            ])
        default:
            return Self.error(id: id, code: -32601, message: "method not found: \(method)")
        }
    }

    /// Why `caller` may not call `name` at all, or nil when it may. The operator may call
    /// anything; a session is refused the operator tools, and every tool when its token
    /// names no tab (a caller Admiral cannot place has no identity to act as), and the
    /// own-tab tools (`ownTabTools`) when they name another tab.
    private func refusal(of name: String, args: [String: Any], for caller: MCPCaller) -> BridgeResult? {
        guard case let .session(token) = caller else { return nil }
        if Self.operatorTools.contains(name) {
            return .failure("\(name) is an operator tool: it is served only on the operator "
                + "endpoint (POST /mcp), never to a session")
        }
        guard let me = bridge.manager.session(forToken: token) else {
            return .failure("refused: the session token names no Admiral tab, so no tool is "
                + "available to this caller")
        }
        // An unknown target falls through, so the tool itself answers "no station".
        if let key = Self.ownTabTools[name],
           let named = (args[key] as? String)?.trimmingCharacters(in: .whitespaces), !named.isEmpty,
           let target = bridge.manager.session(forCallsign: named), target.id != me.id {
            return .failure("\(name) changes only your own tab (@\(me.displayTitle)); "
                + "@\(target.displayTitle) is another tab — only the operator may change it")
        }
        return nil
    }

    /// Tools that change a tab's identity or how its turns end, keyed by the argument naming
    /// the tab. A session may aim them only at itself; the operator at any tab.
    static let ownTabTools: [String: String] = ["rename_station": "to", "set_output_schema": "callsign"]

    private func call(name: String, args: [String: Any], token: String) -> BridgeResult {
        switch name {
        case "callsign":
            return bridge.callsign(token: token)
        case "notify":
            return bridge.notify(token: token, kind: args["kind"] as? String, title: args["title"] as? String,
                                 titleSuffix: args["title_suffix"] as? String, body: str(args, "body"))
        case "roster":
            let entries = bridge.roster(token: token)
            let text = entries.isEmpty
                ? "(no peers)"
                : entries.map { "@\($0.callsign) [\($0.agentType)] \($0.status)" }.joined(separator: "\n")
            return .success(text)
        case "hail":
            return bridge.hail(
                fromToken: token, to: str(args, "to"), body: str(args, "body"),
                needsReply: args["needs_reply"] as? Bool ?? false,
                inReplyTo: args["in_reply_to"] as? String
            )
        case "broadcast":
            return bridge.broadcast(fromToken: token, body: str(args, "body"))
        case "inject":
            return bridge.inject(to: str(args, "to"), text: str(args, "text"))
        case "set_goal":
            guard let goals = Self.goalTexts(args) else { return Self.missingGoals }
            return bridge.setGoal(fromToken: token, to: str(args, "to"), goals: goals)
        case "set_goal_self":
            guard let goals = Self.goalTexts(args) else { return Self.missingGoals }
            return bridge.setGoalSelf(fromToken: token, goals: goals)
        case "add_goals":
            guard let goals = Self.goalTexts(args), !goals.isEmpty else { return Self.missingGoals }
            return bridge.addGoals(fromToken: token, goals: goals)
        case "pr_status":
            return bridge.prStatus(fromToken: token)
        case "AskUserQuestion":
            guard let questions = Self.askQuestions(args) else {
                return .failure("pass `questions`: 1-4 questions, each with question, header, "
                    + "multiSelect and 2-4 options of {label, description}")
            }
            return bridge.askUser(fromToken: token, questions: questions)
        case "update_goals":
            // No list is required — a caller cancelling two goals has no `done` to send, and
            // requiring one had the client reject the call before Admiral ever saw it. What
            // is refused is naming nothing at all.
            let done = Self.ids(args, "done")
            let cancelled = Self.ids(args, "cancelled")
            let open = Self.ids(args, "open")
            guard !(done.isEmpty && cancelled.isEmpty && open.isEmpty) else {
                return .failure("name at least one goal id — in `done` (achieved), "
                    + "`cancelled` (no longer applies), or `open` (reopen it)")
            }
            return bridge.updateGoals(fromToken: token, done: done, open: open, cancelled: cancelled)
        case "rename_station":
            return bridge.renameStation(fromToken: token, name: str(args, "name"),
                                        to: args["to"] as? String)
        case "set_structured_output":
            return bridge.setStructuredOutput(fromToken: token, outputJSON: str(args, "output"),
                                              type: args["type"] as? String)
        case "commission":
            // cwd is required and must exist, so a session never silently lands in the
            // app's home directory when the caller omits it.
            let cwd = (args["cwd"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            var isDir: ObjCBool = false
            guard !cwd.isEmpty, FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
                return .failure("cwd is required and must be an existing directory")
            }
            let provider = (args["provider"] as? String)?.trimmingCharacters(in: .whitespaces)
            return bridge.commission(callsign: str(args, "callsign"), cwd: cwd,
                                     provider: (provider?.isEmpty == false) ? provider : nil,
                                     scratch: args["scratch"] as? Bool,
                                     outputSchema: Self.schemaArgument(args["output_schema"]))
        case "set_output_schema":
            return bridge.setOutputSchema(callsign: str(args, "callsign"),
                                          schemaJSON: Self.schemaArgument(args["schema"]) ?? "")
        case "list_sessions":
            return bridge.listSessions()
        case "session_status":
            return bridge.sessionStatus(callsign: str(args, "callsign"))
        case "focus":
            return bridge.focus(callsign: str(args, "callsign"))
        case "close_session":
            return bridge.closeSession(callsign: str(args, "callsign"))
        case "read_recent":
            let limit: Int
            if let n = args["limit"] as? Int { limit = n }
            else if let s = args["limit"] as? String, let n = Int(s) { limit = n }
            else { limit = 20 }
            return bridge.readRecent(callsign: str(args, "callsign"), limit: limit)
        case "read_screen":
            return bridge.readScreen(callsign: str(args, "callsign"))
        case "send_keys":
            let keys = str(args, "keys").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !keys.isEmpty else { return .failure("keys is required") }
            return bridge.sendKeys(to: str(args, "callsign"), keys: keys)
        case "commission_bash":
            let cwd = (args["cwd"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            var isDir: ObjCBool = false
            guard !cwd.isEmpty, FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
                return .failure("cwd is required and must be an existing directory")
            }
            return bridge.commissionBash(callsign: str(args, "callsign"), cwd: cwd,
                                         scratch: args["scratch"] as? Bool)
        case "fleet_pr_status":
            return bridge.fleetPrStatus()
        case "schedule_list":
            return bridge.scheduleList()
        case "schedule_set":
            return bridge.scheduleSet(ScheduleSpec(
                name: str(args, "name"), newName: args["new_name"] as? String, cron: args["cron"] as? String,
                cwd: args["cwd"] as? String, prompt: args["prompt"] as? String, scratch: args["scratch"] as? Bool,
                outputSchema: Self.schemaArgument(args["output_schema"]), provider: args["provider"] as? String,
                model: args["model"] as? String, effort: args["effort"] as? String,
                enabled: args["enabled"] as? Bool))
        case "schedule_delete":
            return bridge.scheduleDelete(name: str(args, "name"))
        case "schedule_run":
            return bridge.scheduleRun(name: str(args, "name"))
        case "schedule_history":
            let limit = (args["limit"] as? Int) ?? (args["limit"] as? String).flatMap { Int($0) } ?? 20
            return bridge.scheduleHistory(name: args["name"] as? String, runID: args["run_id"] as? String,
                                          limit: limit)
        case _ where name.hasPrefix("group_") && bridge.groups != nil:
            return callGroupTool(name: name, args: args, token: token)
        default:
            return .failure("unknown tool: \(name)")
        }
    }

    /// Reached only while groups are on, so with the flag off a `group_*` call is the same
    /// "unknown tool" as any other name.
    private func callGroupTool(name: String, args: [String: Any], token: String) -> BridgeResult {
        switch name {
        case "group_say":
            return bridge.groupSay(fromToken: token, group: str(args, "group"), text: str(args, "text"),
                                   to: Self.ids(args, "to"))
        case "group_react":
            return bridge.groupReact(fromToken: token, group: str(args, "group"),
                                     message: Self.int(args["message"]), emoji: str(args, "emoji"))
        case "group_log":
            return bridge.groupLog(fromToken: token, group: str(args, "group"),
                                   since: Self.int(args["since"]), limit: Self.int(args["limit"]) ?? 50)
        case "group_list":
            return bridge.groupList(fromToken: token)
        case "group_create":
            return bridge.groupCreate(fromToken: token, name: str(args, "name"), members: Self.ids(args, "members"))
        case "group_add_member":
            return bridge.groupAddMember(fromToken: token, group: str(args, "group"), member: str(args, "member"))
        case "group_remove_member":
            return bridge.groupRemoveMember(fromToken: token, group: str(args, "group"), member: str(args, "member"))
        case "group_rename":
            return bridge.groupRename(fromToken: token, group: str(args, "group"), name: str(args, "name"))
        case "group_delete":
            return bridge.groupDelete(fromToken: token, group: str(args, "group"))
        default:
            return .failure("unknown tool: \(name)")
        }
    }

    /// An integer argument, tolerating the numeric-string form.
    static func int(_ value: Any?) -> Int? {
        (value as? Int) ?? (value as? String).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    // MARK: - AskUserQuestion mirror

    /// The chat view's stand-in for claude's built-in `AskUserQuestion`, which Admiral denies
    /// while a tab shows Chat (its TUI dialog can't be answered from there). Same input
    /// schema as the built-in, so the model passes exactly what it would have passed.
    static let askUserQuestionTool: [String: Any] = [
        "name": "AskUserQuestion",
        "description":
            "Ask the user multiple-choice questions in Admiral's chat view. Use this ONLY when "
            + "the built-in AskUserQuestion was denied because the user is in Admiral's chat view; "
            + "pass exactly the input you gave the built-in. It returns at once: the questions are "
            + "shown to the user, and their answers arrive as their NEXT message. So after calling "
            + "it, end your turn with one short line saying you are waiting for their answers. "
            + "Users can always type their own answer instead of picking an option. If you "
            + "recommend an option, make it the first one and add \"(Recommended)\" to its label.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "questions": [
                    "type": "array",
                    "minItems": 1,
                    "maxItems": 4,
                    "description": "Questions to ask the user (1-4 questions)",
                    "items": [
                        "type": "object",
                        "properties": [
                            "question": ["type": "string", "description": "The complete question to ask the user."],
                            "header": ["type": "string", "description": "Very short label displayed as a chip/tag (max 12 chars)."],
                            "multiSelect": ["type": "boolean", "default": false,
                                            "description": "Allow multiple answers to be selected."],
                            "options": [
                                "type": "array",
                                "minItems": 2,
                                "maxItems": 4,
                                "items": [
                                    "type": "object",
                                    "properties": [
                                        "label": ["type": "string", "description": "The display text for this option (1-5 words)."],
                                        "description": ["type": "string", "description": "What this option means."],
                                        "preview": ["type": "string", "description": "Optional preview content (mockup, code snippet)."],
                                    ],
                                    "required": ["label", "description"],
                                ] as [String: Any],
                            ] as [String: Any],
                        ] as [String: Any],
                        "required": ["question", "header", "options", "multiSelect"],
                    ] as [String: Any],
                ] as [String: Any],
            ] as [String: Any],
            "required": ["questions"],
        ] as [String: Any],
    ]

    /// Decode the mirror's `questions` argument with the same types the ledger stores.
    static func askQuestions(_ args: [String: Any]) -> [AskQuestion]? {
        guard let raw = args["questions"],
              let data = try? JSONSerialization.data(withJSONObject: raw),
              let questions = try? JSONDecoder().decode([AskQuestion].self, from: data),
              !questions.isEmpty else { return nil }
        return questions
    }

    // MARK: - JSON-RPC helpers

    private func str(_ args: [String: Any], _ key: String) -> String { args[key] as? String ?? "" }

    /// A schema argument as JSON text. Advertised as a string, but a client that sends the
    /// schema as an object gets it re-encoded rather than silently dropped.
    static func schemaArgument(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The goal list, or nil when the caller named neither key. An empty `goals` array is a
    /// deliberate "clear them", so it must not look the same as forgetting the argument.
    /// A bare `goal` string is still accepted — the pre-list callers pass one.
    static func goalTexts(_ args: [String: Any]) -> [String]? {
        if let list = args["goals"] as? [Any] { return list.compactMap { $0 as? String } }
        if let single = args["goal"] as? String { return [single] }
        return nil
    }

    /// A list-of-ids argument, tolerating the single-string form a model sometimes sends.
    static func ids(_ args: [String: Any], _ key: String) -> [String] {
        if let list = args[key] as? [Any] { return list.compactMap { $0 as? String } }
        if let single = args[key] as? String, !single.isEmpty { return [single] }
        return []
    }

    private static let missingGoals = BridgeResult.failure(
        "pass `goals` — a list of short completion conditions (an empty list clears them)")

    /// Property types are written as tokens: `string`, `string[]`, and a trailing `?` for
    /// optional. Reading the token here keeps every tool's schema declarative one-liners.
    private static func tool(_ name: String, _ description: String, _ props: [String: String]) -> [String: Any] {
        var properties: [String: Any] = [:]
        var required: [String] = []
        for (key, token) in props {
            let optional = token.hasSuffix("?")
            let type = optional ? String(token.dropLast()) : token
            switch type {
            case "boolean": properties[key] = ["type": "boolean"]
            case "integer": properties[key] = ["type": "integer"]
            case let t where t.hasSuffix("[]"): properties[key] = ["type": "array", "items": ["type": "string"]]
            default: properties[key] = ["type": "string"]
            }
            if !optional { required.append(key) }
        }
        return [
            "name": name,
            "description": description,
            "inputSchema": ["type": "object", "properties": properties, "required": required],
        ]
    }

    private static func result(id: Any?, value: [String: Any]) -> Data {
        encode(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": value])
    }

    private static func error(id: Any?, code: Int, message: String) -> Data {
        encode(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]])
    }

    private static func encode(_ dict: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
    }
}
