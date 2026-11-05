# CLAUDE.md — Admiral developer guide

Guidance for working in `admiral/` (the native macOS Agentic Terminal Manager). Read
this first; deep dives are linked under [docs/](#docs).

## What this is

A SwiftUI + AppKit macOS app that hosts `claude` sessions (and plain `zsh` shells) in
embedded PTYs. See [`README.md`](README.md) for the product overview.

## Two build systems (know which you're in)

| Part | Built with | Tested with |
|---|---|---|
| `AdmiralCore` (headless library) | SwiftPM (`Package.swift`) | `swift test` — **fast (~10s); run this constantly** |
| `App` (the macOS app) | xcodegen → `Admiral.xcodeproj` | `xcodebuild test -only-testing:AdmiralUITests` |

**`AdmiralCore`** is pure logic with no UI/Terminal deps — models, `SessionManager`,
transcript resolution/parsing, the appearance/open-session stores, `BridgeCore`,
`MCPServer`, and the structured-output tripwire. Everything testable headless lives here. The PTY is a
`TerminalHost` protocol so tests use a `FakeTerminalHost`.

`AdmiralCore` has **zero external dependencies**. That invariant is load-bearing:
`admiral/Package.resolved` must never appear (a test asserts it), so `swift test` stays fast
and offline. Never add an external dependency to it — heavy deps belong in the **App** target.

**`App`** is the SwiftUI app + SwiftTerm + App Intents + the bundled `admiral-hook` /
`admiral-bridge-mcp` tools.

## Build / test / run

```bash
# Once per clone: reject non-Conventional commit subjects (they decide the release version)
git config core.hooksPath admiral/.githooks

# Core (do this constantly while changing AdmiralCore)
swift test

# Opt-in ACP end-to-end tests against a real agent in a container (never part of plain `swift test`)
ADMIRAL_ACP_E2E=1 swift test --filter AcpEndToEndTests

# App: regenerate the project after adding files or changing project.yml / deps
cd App && xcodegen generate

# Build the app
xcodebuild -project App/Admiral.xcodeproj -scheme Admiral -derivedDataPath App/build \
  build CODE_SIGNING_ALLOWED=NO

# Rendered-UI tests
xcodebuild test -project App/Admiral.xcodeproj -scheme Admiral -only-testing:AdmiralUITests \
  CODE_SIGNING_REQUIRED=NO

# Install — ONLY when the app isn't running (it hosts live PTY sessions)
pgrep -f "Admiral.app" || echo "safe to install"
rm -rf /Applications/Admiral.app && cp -R App/build/Build/Products/Debug/Admiral.app /Applications/
scripts/sign-app.sh /Applications/Admiral.app && open /Applications/Admiral.app
# …or the whole thing (test + Release build + sign + quit-running + install): scripts/release.sh
# (it stamps the build number CFBundleVersion = git commit count, so every upload is higher)
```

> **Never ad-hoc sign** (`codesign --sign -`) Admiral — always go through `scripts/sign-app.sh`
> (`make build` and `scripts/release.sh` already do). See *Signing* below.

### Signing: Developer ID on a new Mac

Admiral is signed with the Developer ID identity named by `$ADMIRAL_SIGN_ID` (hardened runtime) so
Keychain "Always Allow" and TCC grants survive rebuilds. Keychain access survives rebuilds
**only when signed by the same team** (items get a `teamid:<TEAM_ID>` partition; self-signed/ad-hoc builds are
cdhash-bound and prompt after every rebuild). With a Developer ID provisioning profile at
`App/Admiral.provisionprofile` (gitignored), secrets move to the data-protection keychain under
`<TEAM_ID>.com.pedro.admiral` instead (`Keychain.swift`; setup in docs/signing.md). On a **new Mac**, once:

```bash
# get the identity: Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application
# (Account Holder/Admin only) — OR export cert+key as .p12 from the Mac that has it (strong password), import here
export ADMIRAL_SIGN_ID="Developer ID Application: <Name> (<TEAM_ID>)"   # add to your shell rc
security find-identity -v -p codesigning   # verify "$ADMIRAL_SIGN_ID" is listed
xcrun notarytool store-credentials admiral-notary --apple-id <id> --team-id <TEAM_ID>   # app-specific password
```

Then **always** build/sign via `scripts/sign-app.sh <app>` / `scripts/release.sh` / `make build`, and
`scripts/notarize.sh` (zip → `notarytool submit --wait` → `stapler staple`) for a Gatekeeper-clean copy.

- Order: `ADMIRAL_SIGN_ID` → `Admiral Local Signing` → fail (ad-hoc only with `ADMIRAL_ALLOW_ADHOC=1`).
  Build from a shell that has read your rc, or the Developer ID is not found.
- **Fallback with no Developer ID:** `scripts/make-signing-cert.sh` creates the self-signed `Admiral Local Signing`
  (stable DR, no Team ID → Keychain prompts after each rebuild; the API does not wait on that prompt).
- **First Team-ID build on an existing install:** one Keychain prompt per old item — click **Always Allow** once.
  TCC grants are re-asked once (new designated requirement).
- Full detail: [`docs/signing.md`](docs/signing.md).

Gotchas that have bitten before:
- **Add a new App source file → `xcodegen generate`** or the build won't see it.
- Generated `Admiral.xcodeproj` is gitignored; `project.yml` is the source of truth.
- **`pgrep -x Admiral` NEVER matches.** macOS compares the full `comm`
  (`/Applications/Admiral.app/Contents/MacOS/Admiral`), so the bare name matches nothing and
  it reports "not running" for a live app. Use `pgrep -f "Admiral.app"`, and check
  `pgrep -P <pid>` for children, before touching the bundle. Replacing a running Admiral kills
  the sessions inside it — including, quite possibly, the one doing the work.
- Tabs survive a reinstall (`UserDefaults: admiral.openSessions.v1`); the *running* claude
  children do not, since they are PTY children of the app.

## Headless probes (no UI needed)

The app supports launch flags that run a task and quit — useful for verifying a real
claude spawn without driving the UI:

```bash
APP=App/build/Build/Products/Debug/Admiral.app/Contents/MacOS/Admiral
"$APP" -realCommission ~/admiral-test -realProof ~/admiral-test/proof   # spawn a real claude + dump evidence
"$APP" -probeLinkWiring /tmp/proof.txt   # link clicks route to our Handle, not SwiftTerm's -50 default
"$APP" -probePalette /tmp/proof.txt      # colors 16-255 are the standard xterm cube, not theme-derived
"$APP" -probeSurface /tmp/proof.txt      # the terminal is themed for OUR appearance, not the system's
"$APP" -probeFileDrop /tmp/proof.txt     # a Finder file drop types iTerm2's escaped paths, bracketed
ADMIRAL_DEMO=1 "$APP" -probeTitlebar ~/admiral-test/proof -probeTitlebarTranscript <jsonl>   # the header drags the window
"$APP" -probeSchedule ~/admiral-test -probeScheduleProof <file>   # a cron run + a schema run vs a real claude (isolated)
"$APP" -probeSchedulesUI <dir>    # the real sidebar + Schedules sheet drawn to PNGs, dark and light (isolated, no claude)
open -n -W --env ADMIRAL_SUPPORT_DIR=<tmp> --env ADMIRAL_PROFILE=<unique> App/build/Build/Products/Debug/Admiral.app \
  --args -probeGroupsUI <dir>     # group chat UI (sidebar, window, paused, @ picker, members, New Group, group Footprint vs a tab's, flag off) to PNGs, dark+light
open -n -W --env ADMIRAL_SUPPORT_DIR=<tmp> --env ADMIRAL_PROFILE=<unique> App/build/Build/Products/Debug/Admiral.app \
  --args -probeSheets <dir>       # Schedules + Settings close from their Close button and from Esc on a real window, then PNGs
open -n -W --env ADMIRAL_SUPPORT_DIR=<tmp> --env ADMIRAL_PROFILE=<unique> App/build/Build/Products/Debug/Admiral.app \
  --args -probeAgentsUI <dir>     # Settings → Agents (This Mac/Elsewhere, starting options, rename/delete blocked, API warning),
                                  # ACP tabs, composer (chips, / menu, hint, @ list), tool cards + live output; fixtures to PNGs, dark+light, no agent
```

`-probeTitlebar` guards a **silent** regression: the header looks right, its buttons work, and
dragging it doesn't move the window. The window server does that drag, from a region AppKit
hands it, and SwiftUI subtracts anything hit-testable under the titlebar from that region — a
`.toolbarBackground` color, or a pane's `.background(color)`, which extends up into the titlebar by
default. So the header color is one non-hit-testable fill behind the panes (`RootView`), the
toolbar background stays hidden, pane fills use `paneBackground` (stops at the header), and the
panes are clipped at the header so a scrolled chat can't show through it. The probe reads AppKit's
own description of the region and asserts the empty header is in it, the buttons are not, the
header keeps the pane color (in Chat too, with a transcript), and the sidebar/Footprint buttons
still click. It opens, activates and clicks a real window, so run it isolated (`ADMIRAL_SUPPORT_DIR`
+ a unique `ADMIRAL_PROFILE`). Mutation-test by restoring `.toolbarBackground(Theme.surface, …)` +
`.toolbarBackgroundVisibility(.visible, …)` (the region goes empty) or one pane's
`.background(color)` (that pane's stretch of header stops dragging); the probe must FAIL.

`-probeFileDrop` drives a fresh spawn through AppKit's drop entry points and reads what reaches
the PTY. SwiftTerm registers for no drag types, so `AdmiralTerminalView` (what `spawn` creates)
registers for file URLs and types `TerminalDrop`'s text — iTerm2's escaping, space-joined, one
trailing space — inside bracketed-paste markers while the program has that mode on. Mutation-test
by dropping `registerForDraggedTypes` (AppKit then never routes a drag to the view — silently)
or the bracketing; the probe must FAIL.

`-probeSurface` forces the split that once turned every terminal white — macOS in **light**,
Admiral in **dark** — and asserts the emulator's default background and the view's layer are
both `#121212`, then flips the theme and asserts the **same** terminal relights to `#FFFFFF`.
SwiftTerm bakes whatever color it is handed into a `CGColor` on the view's layer, and since
upstream `e4f31b0` that layer *is* the default background (runs carrying it are no longer
filled). So a dynamic `NSColor` freezes at whatever `NSAppearance.current` was at assignment —
the system's, since the view isn't in the window yet. `Theme.resolved` flattens it against
`SwiftTermHost.appearance` instead, and `AppModel` pushes that from `themeMode`.
Mutation-test both halves: hand `Theme.surfaceNS` over dynamically → the dark checks FAIL;
drop the re-apply loop in `appearance`'s `didSet` → the relit checks FAIL.
**SwiftTerm is pinned to one `revision:` in `App/project.yml`** (it once rode `branch: main`,
and two Macs on the same commit ran different SwiftTerms). Bump that revision on purpose to take
upstream changes, and run this probe after a clean build when you do.

`-probePalette` queries the live emulator over OSC 4. It guards a **silent** regression:
SwiftTerm's `TerminalOptions` defaults `ansi256PaletteStrategy` to `.base16Lab`, which
re-derives colors 16–255 from the terminal's background/foreground every time either is
assigned — so the themed surface drags the whole cube and 256-color TUIs wash out in dark
mode (index 214 → `#ba8425` instead of `#ffaf00`). `SwiftTermHost.pinStandardPalette`
pins `.xterm`; mutation-test by commenting that call out — the probe must FAIL.

This spawns a **separate** process from the build products, so it never touches an installed,
running Admiral. It leaves a real session dir under
`~/Library/Application Support/Admiral/sessions/<token>/` — inspect its `settings.json` to see
exactly what `commission` injected, then remove it. Use a scratch dir under your home (e.g. `~/admiral-test`) as the cwd, not `/tmp`.

## Architecture in one screen

- **`SessionManager`** (Core, `@MainActor`) — owns the tabs, each through one
  `SessionDriver` in `drivers` (it was `handles`, PTY only): `PTYSessionDriver` turns every
  input funnel into bytes on a `TerminalHandle`, `AcpSessionController` into ACP JSON-RPC. The
  backend is decided once, at launch, by which driver a tab gets — never re-asked at a call
  site (`AgentSession.backend`). `commission` spawns
  `claude` inside an interactive login zsh with a deterministic `--session-id`, strips
  Claude-Code env markers (so the child persists its own transcript), sets
  `TERM_PROGRAM=Admiral`, and restores per-**session** appearance (keyed by session id).
  The command line comes from `LaunchOptions` (**Settings → Sessions**, persisted by
  `LaunchOptionsStore`, re-read at every commission): *managed* (default) runs
  `command claude` with app-owned flags (permission mode, optional
  `APPEND_SYSTEM_PROMPT.md` append, extra flags) so personal shell functions/aliases are
  skipped and any machine behaves the same; toggled off, it runs plain `claude` and the
  user's shell config decides.
  `delete`, `move` (reorder), `rename`, `setAppearance`, `setTeam` (a UI-side team label —
  never passed to claude, not exposed over the bridge). Restores sessions on launch via `OpenSessionsStore`
  (resume if a transcript exists, else recreate at the id).
  `claude` session is *managed* (carries the `--session-id` placeholder → transcript,
  restore, injected hooks + bridge MCP); a **Bash** session (`bashAgentType`, `zsh -il`) is
  *unmanaged* — no session-id, transcript, hook, or restore.
  `commission` injects two per-session files symmetrically, each best-effort (the flag is
  appended only if the file was written, since a missing path makes claude refuse to launch):
  `--settings` (hooks) and `--mcp-config` (the bundled bridge relay).
- **Custom model — per tab, never global.** `CCSwitchCatalog` reads the [CC Switch](https://github.com/farion1231/cc-switch)
  app's SQLite config **read-only** (`~/.cc-switch/cc-switch.db`, or the folder/file picked in Settings →
  Sessions → Choose…, kept as a security-scoped bookmark so a sandboxed build can still read it —
  `CCSwitchCatalog.load(bookmark:)` is the one entry point; WAL → falls back to a temp copy) and offers its Claude configs. Ticking "Use custom model" on the New-session form
  launches that tab with the config's env (`ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, the
  model names) written into **that session's `--settings` file** — claude's highest-precedence
  settings source, so it wins over `~/.claude/settings.json`, and the token stays out of
  `ps eww` (the file is `0600`). Admiral never writes to CC Switch or to the global config, and
  no other tab is affected. Settings → Sessions picks *which* config the checkbox means;
  choosing there launches nothing. The provider id rides on `AgentSession` and
  `OpenSessionRecord`, so reload/fork/restore come back on the same endpoint (re-resolved
  through `providerResolver`, which picks up a token rotated in CC Switch). Two caveats worth
  knowing: a custom-provider tab loses claude.ai-hosted connectors (another auth source takes
  precedence over the claude.ai login), and an unknown model name assumes a 200k window unless
  it carries a `[1M]` suffix.
- **Hooks — Admiral does NOT govern.** Governance is `hookd` (a separate repo), a
  Python daemon registered globally in `~/.claude/settings.json`, so it covers every session
  rather than only the ones Admiral launched. Admiral injects a settings file carrying only the
  events its **own** features need, each with no other delivery path: `PostToolUse` (the
  touched-repos log), `Stop` (the structured-output tripwire that drives
  `set_structured_output` — one file holding a **slot per `ArmType`** (`api`/`watchdog`/`goals`),
  each with its own schema and budget; a Stop block carries one reason, so the
  highest-priority armed slot wins the turn and only its blocks move; then, if nothing is
  owed, one goal-review block when the turn ends with goals open), `UserPromptSubmit`
  (the watchdog's prompt log, plus the open-goals reminder — sent in full only when it
  changed, tracked in `goals/<sid>.reminded`, since hook context stays until compaction),
  `SessionStart` (matcher `clear|compact` only: forgets that marker so the reminder goes out
  in full again), and the **Chat view**'s three:
  `UserPromptSubmit`/`Stop`/`Notification` append to the chat ledger, and `PreToolUse`
  (matcher `AskUserQuestion` only) denies the built-in while the tab shows Chat. An API
  tool tab (`POST /v1/messages` with `tools`, see `docs/client-tools.md`) registers that
  hook with no matcher and denies every tool that is not `mcp__client__*`; its
  UserPromptSubmit context is the client catalog instead of the goals reminder. **A hook's plain stdout is never
  shown in the transcript** — it reaches the model and nobody else. Anything the *user* must
  see goes in `systemMessage`; the model's half is `hookSpecificOutput.additionalContext`
  (UserPromptSubmit) or `reason` (Stop). `GoalsReminder` hand-builds both, so the bytes are
  assertable and mutation-tested. Every arm needs `ADMIRAL_SESSION` (the helper is a no-op
  without it). The bundled `admiral-hook`
  helper **always exits 0** — a Stop block is conveyed purely by the stdout JSON, so a wrong key
  silently stops it working. Another event here means a new Admiral feature — never a rule.
  An **ACP tab** takes no `--settings` file, so nothing runs `admiral-hook`: `AcpHookAdapter`
  calls the same `HookDispatcher` arms in-process at the ACP moments (prompt out →
  `UserPromptSubmit`, `end_turn` → `Stop`, a completed edit → `PostToolUse`, compaction →
  `SessionStart`).
- **Native notifications** — Claude Code never emits OSC 9/777 under `TERM_PROGRAM=Admiral`
  (its `auto` channel finds no method; `preferredNotifChannel` is a global `~/.claude.json`
  key with no env/flag override, so Admiral does not touch it). Instead the hooks notify:
  terminal-mode `PreToolUse`/`AskUserQuestion` → "@CALLSIGN is asking" + first question;
  `Notification` types `permission_prompt`/`elicitation_dialog`/`idle_prompt`/
  `agent_needs_input` → "@CALLSIGN needs you" (`HookNotification` maps payload → note).
  The helper delivers over the bridge socket (`HookNotifier`, 1.5 s bound, best effort) as a
  `notify` tool call with internal `kind`/`title_suffix` args → `BridgeCore.notify` →
  `NotificationService.post(kind:…)`. **That `post` is the only gate**: master
  `admiral.notificationsEnabled` plus `admiral.notify.{question,needsInput,terminal,done,nudge}`
  (all default on except `nudge`, default off; `NotificationPolicy`), so OSC, hooks, the bridge `notify` tool, and the
  watchdog "claims done" / goals-met (`.done`) can't bypass Settings → Notifications. Viewing a tab (app active +
  selected) suppresses `terminal`/`needsInput` only. Only "done" notifies (watchdog `.notifyDone`,
  goals `.notifyAllDone`); the nag/probe nudges are typed into the tab and post nothing — `.nudge`
  (default off) is reserved so any future nudge notification is opt-in. Existing tabs keep old hook files
  until restarted.
- **Goal guidance is data, not a literal** — `GoalGuidance` reads
  `<supportDir>/goal-guidance.txt` (plain prose; absent or blank = the built-in), and
  `tools/list` splices it into both `set_goal` descriptions *as it answers*, so an edit lands
  on the next session without an app restart. It steers between the two ways a goal goes bad:
  unsettleable ("make auth robust") and mechanical ("swift test passes" — provable, but true
  of every task ever asked). The enforced limits are appended by code, never by the file.
- **PR watch** — `PRWatchService` polls `gh` for the PRs on the repos a session has written to
  and injects when one moves (blocked/mergeable/merged, checks, approvals); the `pr_status`
  tool reads the same record on demand. It runs **only where that session's watchdog is
  armed** — the gate is the cost control, not a preference, or Admiral becomes a GitHub poller
  for every idle tab. What it compares is a coarse `PRDigest` (state × checks × approvals),
  because raw check counts churn all through a CI run and would inject a dozen times.
  `<base>/pr-watch/<session>.json` records what the session was **told**, separately from what
  was merely polled: that split is what lets news held while a session cannot be typed to be
  delivered later instead of lost, and what stops a relaunch or a `--resume` from announcing
  everything again. It is delivered **at once, busy or idle** (claude takes a mid-turn
  message); only an open dialog (claude's `"waiting"`) or a claude that is not running holds it.
- **How Admiral's messages arrive** — PR watch and the watchdog go through
  `SessionManager.deliver`: a tab launched with Settings → Sessions "Messages from Admiral" on
  (default) carries `crossSessionInbound: "accept"` in its `--settings` file
  (`AgentSession.acceptsPeerMessages`), and gets the message on claude's messaging socket — never
  typed over a half-written prompt. Any other tab, or a socket that is missing or refuses, is typed
  into. Without `accept`, claude **holds** a socket message to a `bypassPermissions` session
  ("Held peer message — not delivered") — probed on 2.1.286, both ways.
- **Watchdog reminder** — while a tab's watchdog is armed, `WatchdogService` mirrors the trigger to
  `sessions/<token>/watchdog.json`; the Stop hook (`WatchdogReminder`) then blocks once per user
  prompt asking the session to report `done` via `set_structured_output` if the work is finished.
  It ranks last: a pending probe, then the goal review, take the Stop first.
- **Chat view** (default for claude tabs; ⌘J swaps to the terminal — only the terminal region
  swaps, the status bar stays). Its timeline (`ChatHistory`) merges two sources. **The
  transcript** supplies the conversation: every prompt, every agent message (mid-turn
  narration as well as the answer), and notices for hook feedback, API errors, slash
  commands and their output, interrupts, compactions, and task notifications. **The chat
  ledger**, `<base>/chat/<session_id>.jsonl`, adds only what the transcript can't say:
  AskUserQuestion-mirror questions, permission prompts, and which prompts Admiral typed. Its
  Stop replies are recorded but never shown, because the transcript holds them too (a test
  guards against double-showing). The ledger is keyed by claude's session id like goals,
  because `ADMIRAL_SESSION` changes every launch. The live window is the newest page, parsed
  from the transcript's tail each tick; older pages load on scroll-up. A message, once shown,
  never changes. The composer **types** into the PTY (`SessionManager.sendTyped`): it never uses a
  bracketed paste, because claude wraps a paste in `<pasted_content>` and treats it as
  untrusted, and newlines go as LF (Ctrl+J). `\`+CR left a literal backslash in longer
  messages. **AskUserQuestion**: while the tab shows Chat
  (`<base>/chat/<sid>.mode`, absent = chat), the `PreToolUse` hook denies the built-in and
  points the model at the bridge's same-schema `AskUserQuestion` mirror. The mirror records
  the questions and returns at once, and the card types the answers back as the next prompt.
  `SessionManager.inject` marks what Admiral types, so those prompts show as Admiral's.
  `-probeChat <cwd> -probeChatProof <file>` proves all of it against a real claude (run it
  isolated).
- **Schedules** — `SchedulerService` (Core) on the 1 s tick: a due cron opens a NEW tab named
  exactly after the schedule (`StationName` rule; scratch by default; a claude model by its CLI
  alias — sonnet/haiku/opus/fable, opus by default — plus an optional effort level and output
  schema, each passed to the run's `claude` as `--model`/`--effort`; optional CC Switch custom
  model) and types its prompt through `TabRun`, the run lifecycle it shares with the
  Anthropic endpoint. `<base>/schedules/<id>.json` per schedule; `<id>/runs.jsonl` is only an
  index pointing at each run's claude session — what a run did is that session. Missed fires run
  once, late; a run still going makes the next skip. Only the instance holding
  `schedules/.lock` (`SchedulerLock`) runs them. Driven by the `schedule_*` bridge tools and the
  Schedules sheet.
- **ACP agents** — Settings → Agents (`AcpAgentStore`, `admiral.acpAgents.v1`) lists agents
  reached over the Agent Client Protocol: a launch command (`npx -y <agent-package>@<version>`,
  or one that enters another environment first) and **where it runs** (`AcpWorkspace`, "Runs
  on"). **This Mac**: `cwd` is a Mac path, git/gh run directly (`LocalCommandRunner`, PATH
  resolved per run), bridge URL fixed at `http://127.0.0.1:4142`. **Elsewhere** (a container,
  a VM, an SSH host): an explicit **Exec** prefix runs one command next to the agent
  (`ExecCommandRunner`, bounded; none = git/branch/touched repos/PR watch off) and a **Bridge
  URL** says how that place reaches the Mac. Nothing in the form assumes docker; a legacy agent
  is migrated on decode. **Starting options** are the agent's own config options
  (`defaultConfigOptions`), picked in Settings from `AcpOptionCatalogStore` (what the agent last
  advertised, saved at each session start) — there is no default *mode* field. They apply only
  to a **new** session (never a load/resume); an option or value the agent does not offer is
  skipped and logged. `commissionACP` opens a **Chat-only** tab on one: `AcpSessionController`
  runs the handshake, the turn, the client-side queue/steering, and holds the agent's
  permission and elicitation requests as Chat cards (never auto-approved). An accepted input
  is certain to go out (`acceptanceIsDelivery`), so `TabRun` never retypes into an ACP tab.
  Agents write no transcript Admiral can read, so `TranscriptMirror` writes a claude-shaped
  **mirror** at `<base>/acp/<sid>.jsonl` (traffic log beside it, `<sid>.log`, bearer masked);
  Chat, TabRun and the Anthropic endpoint read that like any transcript. A tool result there
  carries a claude-shaped `toolUseResult` (an edit's `filePath/oldString/newString/type`, a
  command's `stdout`). A `/command` prompt (`AcpSlashCommand`) goes out bare — no goals
  reminder, never as a steer — and is mirrored as claude writes one, so Chat shows it as a
  command; a `/clear` that ended normally writes a marker (`ChatHistory.clearedField`) and Chat
  shows nothing older; a compaction shows when it completes or fails. The composer pieces are **ACP tabs only**: option chips
  (`acpConfigOptions` — mode, model, … — set on the agent, a refusal shown above the text), the
  `/` menu (`acpCommands`, `SlashCommandPicker`; a command's `input.hint` after it), and the `@`
  menu (`FileMentionPicker` over `SessionManager.acpFiles` — `git ls-files -z` through the tab's
  runner, cached 30 s), whose picks go out as `resource_link` blocks beside the typed text. So
  are **tool cards** (`ChatItem.tool`): a row per call that opens on its output (last lines,
  bounded) or its diff (`LineDiff`); a PTY tab's Chat never shows them. A running command's
  output streams into `AgentSession.acpLiveOutput` (last 8 KB, published once per window) and
  its tail shows under Working…. A tab is found by its agent's **name**, so rename and delete
  are refused while a tab is open on it.
- **Session bridge listener (:4142)** — an ACP agent cannot use the bridge relay's Unix socket
  (it may not even share the filesystem), so `POST /mcp/session` on 127.0.0.1:4142
  (`SessionMCPEndpoint`) serves the session tools. Agents are told `mcpCallbackURL`: always
  `http://127.0.0.1:4142` for This Mac; for Elsewhere, the Bridge URL (e.g.
  `http://host.docker.internal:4142` from Docker, or a reverse tunnel for an SSH host).
  It runs only while an agent is configured (`SessionBridgePolicy`), never falls back to
  another port, and is **token-gated**: `Bearer <tab token>`, valid only while it names a live
  ACP tab, always `.session(token)` (no operator tools). A request carrying `Origin` is refused
  before the token is read. No Host allowlist (a container's Host is
  `host.docker.internal`) — the token is the gate. The API server on :4141 is untouched.
- **Transcript** — `TranscriptLocator` resolves the `.jsonl` (ported from the bridge's
  `ResolvePath`/`EncodeProjectDir`); `TranscriptParser`/`TranscriptStore` parse it.
- **Terminal** — `TerminalHost` protocol (Core) + `SwiftTermHost` (App, real PTY).
  **Shift+Enter → newline:** claude's TUI needs the kitty keyboard protocol to tell
  Shift+Return from Return, but it isn't active in SwiftTerm here, so AppKit collapses
  both into `insertNewline:` and the prompt submits. `SwiftTermHost` installs a local
  `NSEvent` keyDown monitor that, when a terminal is first responder, intercepts
  Shift+Return and sends `\`+Enter (the backslash-continuation claude treats as a
  newline), consuming the event. SwiftTerm's `keyDown` is non-`open`, so it's a monitor,
  not a subclass. (Diagnosed: not the launch/focus/accessibility — works in iTerm2,
  whose emulator negotiates the protocol.)
- **UI** — `AppModel` wires it all and forwards the `SessionManager`'s `ObservableObject`
  changes; `RootView` (titlebar header + sidebar + detail), `SidebarView`, `DetailView`.
  `Theme` centralizes colors (one `surface` color for header/sidebar/content/terminal so
  the blacks match; dark = Warp `#181818`).
- **Persistence** — appearance + open sessions + theme + collapse state → app `UserDefaults`.

## Conventions

- Keep logic in `AdmiralCore` so it's covered by fast `swift test`. UI-only code lives in `App`.
- New session kind = a new `AgentType` value, not new branches (e.g. `bashAgentType` in
  `AppModel` launches `zsh -il`; the `--session-id` placeholder in an agent's `defaultArgs`
  is what makes a session *managed*).
- Adding a keyboard shortcut: add the key string to `Shortcuts` (ShortcutsHelp.swift), bind it
  in `AdmiralCommands` (AdmiralApp.swift), AND add a `PaletteCommand` row to
  `CommandPalette.commands` so it shows in the ⌘/ palette (which doubles as the shortcuts
  cheat sheet). Forgetting the palette row is an easy miss.
- When you change `SessionManager`/stores, add a fast unit test (they're ~ms).
- New governance rule = a new Python rule in `hookd` (`src/hookd/hooks/rules/`), not
  anything in this repo. Assert the **exact** message string in its test; it is shown in the
  Claude Code UI.
- Never add an external dependency to `AdmiralCore`. `admiral/Package.resolved` must not exist.
- **Mutation-test anything guarding a silent failure** (the Stop tripwire's wire JSON, the
  atomic-append touched log). A golden that cannot fail is worse than no golden — and verify the
  mutation actually *compiled*, because a build failure produces no test output and looks
  exactly like a pass.

## Code design review (practice)

Before opening a PR, run a **design-quality pass** over the diff (not the whole repo),
using the `/code-design-review` skill. It's distinct
from correctness review and generic cleanup, and it reviews **only** branching & decision
placement today — other design concerns are out of scope unless the skill grows a rubric.

**Core principle — the goal is NOT fewer `if`s.** It's (1) each decision made *exactly
once*, and (2) a *smaller reachable state space*. Forks breed bugs by multiplying states
and by decision drift (the same question re-asked at N sites that then diverge). Deleting
a branch only counts if it removes a decision site or shrinks the state space.

**Classify each conditional before treating it** (most over-firing comes from skipping
this). Swift-flavored taxonomy:

| Smell | Looks like (Swift) | Fix | Fire only when |
|---|---|---|---|
| Boundary guard | `guard` / fail-fast at entry | **KEEP** (hoist earlier, fold into one source of truth) | never a smell |
| Optionality fork | `if let x` on a *collaborator* repeated | Null Object chosen once at construction | same optional checked at **≥2 sites** |
| Mode/type discriminator | same `switch agentType` / `status ==` / bool branched around | decide once at the edge — a value (`AgentType`), dispatch dict, or strategy | same discriminator at **≥2 sites** |
| Untyped contract parse | a result re-interpreted through fallback layers | parse don't validate: type the producer (struct/`Result`/enum); consumers collapse | producer in scope (else name it as the out-of-scope root cause) |
| Capability sniffing | `as?`/`responds(to:)`/`is` repeated to pick behavior | normalize once at the adapter/registration point | same sniff at ≥2 sites, or any sniff in a loop |
| Flag argument | `Bool` param forking a function internally | split into two functions | one site suffices |
| Error-path fork | the same error re-checked along a flow | throw at the boundary, or one typed `Result` checked once | same error re-checked downstream |

**The ladder — smallest tool wins:** guard clause → merged expression → extracted helper →
dispatch dict → Null Object → config-object/strategy → protocol/enum hierarchy. Pick the
*lightest* rung that consolidates the sites; a Strategy where a frozen struct of values
suffices adds a concept while consolidating nothing.

**Must NOT "fix" (leave them):**
- A **single-site** `switch`/`is` over a closed set (one location). If silent fall-through
  is a hazard, add an `default:` that errors — that's correctness, not a pattern. "A 4th
  case will be easy later" is speculative; fire on the *second* site, not the hypothetical.
- **Boundary guards** — one upstream guard deletes N downstream defensive forks.
- **Documented defense-in-depth / security re-checks** (a comment says it's deliberate).
- Don't cosmetically polish identical branch bodies that are really an **untyped contract**
  — name the missing type instead.

**Every finding carries:** the *sites* (functions/lines), *fork accounting* (decision
sites / reachable states before → after — if it doesn't drop, the finding dies), and the
*cost* (the new concept the reader must learn). End with a **"Kept (deliberate)"** list of
the guards / single-site dispatches / documented re-checks you classified and left alone.

This codebase already leans on the antidotes: `AgentType` is a *value* (new session kind =
new value, not new branches); the PTY is one `TerminalHost` protocol. Keep new code in
that shape.

## docs

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — components, data flow, persistence.
- [docs/releasing.md](docs/releasing.md) — releases made by hand with `scripts/release-local.sh`: version
  from commit types, build number from the commit count, signed + notarized DMG.
- [docs/bridge-reconciliation.md](docs/bridge-reconciliation.md) — what Admiral reuses
  from / shares with the iTerm2 bridge, and where it diverges.
