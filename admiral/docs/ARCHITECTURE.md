# Architecture

Admiral is split into a headless, fast-testable core (`AdmiralCore`, SwiftPM) and the
macOS app (`App`, xcodegen). The dependency rule: **logic lives in Core; UI / Terminal
live in the App.**

## Module map

```
AdmiralCore (SwiftPM target, ZERO external deps — no UI, no SwiftTerm — `swift test`)
  Models/        AgentSession, AgentType, Conversation, SessionStatus
  Session/       SessionManager, TranscriptLocator, TranscriptStore, ProcessTree,
                 ClaudeSessionFile, Git, SessionAppearanceStore, OpenSessionsStore
  Transcript/    RawLine, JSONValue, TranscriptParser, ToolFormatter, PlanFolder, TitleAccumulator
  Bridge/        BridgeCore (callsign/roster/hail/broadcast/commission over app sessions)
  MCP/           MCPServer (served over the bridge socket; injected per session)
  Hooks/         HookDispatcher, HookSettings, PostToolUseHandler, HookLog,
                 TouchedRepos(Reader), AtomicAppend, AdmiralPaths
  StructuredOutput/ ArmType, StructuredOutputStore (slots keyed by arm), StopInstruction
                 (the Stop tripwire — one block per turn, highest-priority armed slot wins)
  Goals/         SessionGoals (+ validation), GoalsStore, GoalsMachine/GoalsService
                 (the idle → probe → nag loop that closes a session's goals)
  ACP/           AcpSessionController (the ACP SessionDriver), JSONRPCConnection, AcpTransport,
                 TranscriptMirror, AcpHookAdapter, AcpAgentConfig/Store, SessionMCPEndpoint
  Support/       GitHubEnvironment (token + gh path for a Finder-launched app), CommandRunner
  Terminal/      TerminalHost protocol (the PTY seam)

App (SwiftUI + AppKit + SwiftTerm)
  AdmiralApp     @main scene; Commands (keyboard shortcuts)
  AppModel       wires Core + host + bridge; drives the 1s refresh tick; theme/selection
  AppState       shared singleton for App Intents
  Theme          semantic colors (one `surface` color; dark = Warp #181818)
  Views/         RootView, SidebarView, DetailView, NewTerminalForm, AvatarEditorPopover, StatusBar, ShortcutsHelp, Snapshot
  Terminal/      SwiftTermHost (real PTY implementation of TerminalHost)
  Bridge/        BridgeSocketServer, AnthropicHTTPServer
  Intents/       App Intents + AgentSessionEntity (IndexedEntity) + AdmiralShortcuts

App/HookHelper     → `admiral-hook`        (xcodegen `type: tool`, embedded in Contents/Helpers)
App/BridgeMCP      → `admiral-bridge-mcp`  (same)
```

## Terminal sessions

`SessionManager.commission(callsign:cwd:agentType:sessionID:resume:)`:

1. Generate a fresh `--session-id <uuid>` (or reuse one when resuming) so the transcript
   path is deterministic and isolated per terminal.
2. Strip Claude-Code env markers (`CLAUDECODE`, `CLAUDE_CODE_*`, …). A hosted claude that
   inherits them runs as a *child* session that never persists a transcript — this was a
   real bug. Set `TERM`, `ADMIRAL_SESSION`, and host markers `TERM_PROGRAM=Admiral` /
   `ADMIRAL=1` (so the bridge can distinguish Admiral from iTerm2).
3. Write the per-session config files and append them to the launch — the two injections
   are symmetrical, and each is **best-effort**: the flag is appended only if the file was
   actually written, because pointing `claude` at a missing path makes it refuse to launch.
   - `--settings '<…>/sessions/<token>/settings.json'` — a **hooks-only** file
     (`HookSettings`) registering `PostToolUse`, `Stop`, `UserPromptSubmit`, `Notification` and
     `PreToolUse` (matcher `AskUserQuestion`, for the Chat view). Claude Code
     unions hooks across settings sources, so the user's own hooks and `permissions` are
     untouched. These are not governance — see below.
   - `--mcp-config '<…>/sessions/<token>/bridge-mcp.json'` — registers Admiral's own bundled
     `admiral-bridge-mcp` relay as `bridge`, non-strict, so the user's other MCP servers
     still load.
4. Spawn via the `TerminalHost` (SwiftTerm PTY in the app; fake in tests).
5. Restore per-cwd appearance (custom name/color/icon) and record the open session.

**Transcript resolution** (`TranscriptLocator`, ported from the bridge's `ResolvePath` /
`EncodeProjectDir`): an Admiral-spawned session resolves *only its own* transcript — the
exact `<session-id>.jsonl`, or the newest `.jsonl` created at/after spawn — never another
session's file. The 1s tick re-resolves until it locks the exact file, then tails it.

**Restore on launch**: `OpenSessionsStore` persists `{cwd, sessionID, callsign}`. On a
plain launch each is re-commissioned: `--resume <id>` if claude wrote that transcript,
else recreated fresh at the same id (so an empty, never-used session reopens instead of
erroring "session not found").

**Process discovery**: `ProcessTree.snapshot()` (a `ps` parse — drains the pipe *before*
`waitUntilExit`, or it deadlocks on >64 KB output) and a descendant-only `findClaudePid`.

## ACP tabs

A tab on an ACP agent (Settings → Agents) has no PTY: `SessionManager` holds a
`SessionDriver` per tab in `drivers`, and an ACP tab's is an `AcpSessionController` over
`JSONRPCConnection` (newline-delimited JSON-RPC on the agent's stdio, e.g. `docker exec -i`).
Every input funnel — composer, inject, deliver — joins the controller's queue: sent as a
prompt when idle, as a steer mid-turn when the agent advertises it. Accepted means it will go
out, so `TabRun` sends once and never retypes.

```
agent ◀─stdio─▶ JSONRPCConnection ─▶ AcpSessionController ─▶ TranscriptMirror  <base>/acp/<sid>.jsonl
                                       │                   ─▶ ChatLedger (permission / question cards)
                                       └─ AcpHookAdapter ──▶ HookDispatcher (same arms as admiral-hook)
```

- **Mirror transcript.** The agent's own history is out of reach, so the controller writes
  claude-shaped lines; Chat, `TabRun` and restore read it as a transcript. `session/load`'s
  replay is dropped when the mirror already exists.
- **Hooks in-process.** No `--settings` file, so `AcpHookAdapter` dispatches
  `UserPromptSubmit` / `Stop` / `PostToolUse` / `SessionStart` at the ACP moments. A Stop
  block's reason is sent as the next prompt, bypassing `UserPromptSubmit`, and recorded in
  the ledger as Admiral's.
- **Where git runs.** `CommandRunner`: the Mac (`LocalCommandRunner`) for PTY tabs, the
  agent's environment (`ExecCommandRunner`, 5 s bound; gh 30 s) for ACP tabs. Both pipes are
  drained while the command runs.
- **Session bridge (:4142).** `POST /mcp/session` on loopback serves the session tools to an
  agent that cannot reach the bridge socket. Token-gated (`Bearer <tab token>`, live ACP tabs
  only, caller always `.session`), `Origin` refused, no port fallback; up only while an agent
  is configured. :4141 (the API server) is unchanged.

## Hooks (what Admiral still needs delivered)

**Admiral does not govern.** Rule-based governance lives in `hookd` (a separate repo), a Python
daemon registered globally in `~/.claude/settings.json`, so it applies to every session on the
machine rather than only the ones Admiral launched.

What remains here are two Admiral features that a hook is the only way to deliver.
`admiral-hook` — a bundled tool, invoked by Claude Code as a `command` hook — reads the
payload on stdin and writes to stdout. It **always exits 0**; a Stop block is conveyed by that
JSON alone, so a wrong key silently stops it working.

```
Claude Code ──▶ admiral-hook claude <Event> ──▶ HookDispatcher
                                                  ├─ PostToolUse      → TouchedRepos
                                                  ├─ UserPromptSubmit → WatchdogPromptHandler
                                                  └─ Stop             → StructuredOutputStore
                                                                      → StopInstruction → stdout JSON
```

All three arms need `ADMIRAL_SESSION` — each reads or writes under `sessions/<token>/` — so a
missing token makes the whole dispatch a no-op. Every other event is a no-op too. A fourth arm
would mean a new Admiral feature that needs a hook — never a rule.

## UI wiring

`AppModel` is the SwiftUI root object. SwiftUI does **not** propagate a nested
`ObservableObject`'s changes to the parent's observers, so `AppModel` forwards
`SessionManager`'s `objectWillChange` — without this, commissioning mutates state but
views don't redraw (a bug we hit). The detail pane shows the selected terminal.

`Theme` uses one `surface` color for the header (titlebar, tinted via `toolbarBackground`),
sidebar, content, and the SwiftTerm background, so all the "blacks" match (dark =
Warp `#181818`). Appearance (auto/light/dark) and sidebar collapse state are persisted.

## Persistence summary

| What | Where |
|---|---|
| Per-session appearance (name/color/icon) | `UserDefaults: admiral.sessionAppearances.v2` |
| Open sessions (for restore, ordered) | `UserDefaults: admiral.openSessions.v1` |
| ACP agents | `UserDefaults: admiral.acpAgents.v1` |
| ACP mirror transcript + traffic log | `<support>/acp/<sid>.{jsonl,log}` |
| Theme mode / sidebar collapsed | `UserDefaults: admiral.themeMode / admiral.sidebarCollapsed` |
| Injected hooks + MCP config, touched-repo log | `<support>/sessions/<token>/{settings.json, bridge-mcp.json, touched.jsonl}` |
| `once_per_session` rules already fired | `<support>/hooks/fired/<payload session_id>.jsonl` |

`<support>` is `~/Library/Application Support/Admiral` (**not** profile-scoped; only the
UserDefaults suite and the bridge socket are). The fired-rules ledger deliberately sits
*outside* `sessions/<token>/`, so `delete` cannot drop governance state, and so it works for a
session id Admiral never minted. Both `touched.jsonl` and the ledger are appended through
`AtomicAppend` (`O_APPEND` + one `write(2)`), because Claude Code runs hooks for parallel tool
calls concurrently and several short-lived helper processes write at once.

Appearance is keyed by **session id**, not folder: a brand-new terminal always starts
fresh, two sessions in the same folder never collide, and a restored session gets its own
look back. Deleting a terminal clears only its own persisted appearance.
