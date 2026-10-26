# Admiral — Agentic Terminal Manager

A native macOS app that hosts and commands a fleet of **Claude Code** sessions.

Each terminal runs `claude` in a real PTY (SwiftTerm) inside the app — no iTerm2
dependency. You can also open a plain **`zsh`** login shell ("New Bash") in any folder.

> Admiral grew out of an iTerm2 bridge and keeps its nautical metaphor: the Admiral
> commands a fleet of *stations*, each with a *callsign*, that *hail* and *broadcast*.

## What it does

- **Hosts terminals** — spawns `claude --permission-mode bypassPermissions` in a PTY,
  one per session, isolated by a deterministic `--session-id`. Sessions restore on
  relaunch (`--resume`).
- **Sidebar** — terminals in one list: select, **rename**, pick a **color +
  icon**, set a **team**, **delete** (confirmed), **drag to reorder**, and **search**.
  Rows are keyboard-focusable (Return/Space select, Delete removes). Collapses to an
  icon rail (state persisted).
- **Teams** — group sessions under a team label (the promote sheet or the edit popover);
  the status-bar team chip lists your teammates. UI-side only — never passed to claude,
  not exposed over the bridge.
- **Keyboard shortcuts** — ⌘T new Claude Code, ⌃⌘T new Bash, ⌘F search, ⌘B collapse,
  ⌃⌘A appearance, ⌃⇥/⌃⇧⇥ next/prev, ⌘1–9 select, ⌘⌫ delete, ⌘/ command palette.
- **Shift+Enter** in a terminal inserts a newline in claude's prompt (instead of
  submitting) — synthesized in `SwiftTermHost` since SwiftTerm doesn't negotiate the
  kitty keyboard protocol that would distinguish it.
- **Theme** — auto / light / dark (persisted); dark is Warp's `#181818`.
- **Siri / App Intents** — list, status, send, set goal, hail, broadcast, commission,
  open; sessions are indexed in Spotlight (`IndexedEntity`).
- **Bridge parity** — station tools `callsign / roster / hail / broadcast / set_goal /
  set_goal_self / add_goals / update_goals / pr_status / commission / rename_station /
  set_structured_output / notify` over the app's own sessions (`notify` posts a native
  notification for the caller's tab; Claude's AskUserQuestion and needs-input hooks do too —
  Settings → Notifications toggles each kind). Hosted
  claudes carry `TERM_PROGRAM=Admiral` so the bridge can tell them apart from iTerm2
  sessions. A `hail` asks for nothing back; `needs_reply: true` says so in the text and
  hands the station the id to quote in `in_reply_to`.
- **Operator MCP** — fleet tools on the same `MCPServer`, served only to the operator: a
  session (the bridge socket) neither sees nor may call `list_sessions / session_status /
  inject / send_keys / read_screen / focus / close_session / read_recent / commission_bash /
  fleet_pr_status`. They are on **:4141 POST /mcp**. The chat API on the same server
  (`POST /v1/messages`) and the session event stream do not require an API token.
  Cloudflare Access gates the public hostname.
- **Goals** — `set_goal` takes a **list** of short completion conditions (≤ 280 chars each,
  at most 10; an empty list clears them). They are stored per session and shown in the
  Footprint panel, where right-clicking a goal marks it met, reopens it, or cancels it, and the
  section's `…` menu clears them all. They are never typed into the session as a `/goal`: that
  arms Claude Code's own stop condition, which Admiral could neither see nor clear. While any goal is
  open, an idle session is probed for a structured per-goal answer and nagged with whatever
  is left. Every prompt carries a visible reminder of what is still open, and ending a turn
  with an open goal is blocked once so the session has to account for it. The session closes
  a goal itself with `update_goals(done: ["g2"])`, or `cancelled: ["g2"]` when it no longer
  applies — a cancelled goal leaves the panel but stays in the record.
  **Setting a new goal list is refused while any goal is still open**, naming each one, so a
  fresh directive can never quietly erase an unfinished one. Settings → Watchdog → Goals owns
  the toggle and thresholds, separately from the watchdog's.
  **How goals should be written** is itself editable — Settings → Watchdog, or the file
  `~/Library/Application Support/Admiral/goal-guidance.txt`, which a session can rewrite as
  easily as you can. It is spliced into the `set_goal` tool descriptions at the moment a
  session asks for the tool list, so an edit reaches the next session without restarting
  Admiral; delete the file (or empty it) to go back to the built-in text.
- **PR watch** — while a session's watchdog is armed, Admiral polls the pull requests on the
  repos that session has written to and tells it when one moves: checks went red, the last
  approval landed, it became mergeable, it got merged. Only real movement is announced (a
  running check suite counting down is not news), each change exactly once — the record of
  what a session has been told is a file, so a relaunch or a `--resume` stays quiet. `pr_status`
  returns the same picture on demand, with its age. Sessions nobody is watching are never
  polled.
- **Hooks** — Admiral injects a small settings file with the session (`--settings`, alongside
  `--mcp-config` for the bridge relay): one event records which git repos the session wrote to,
  one delivers structured output on demand, one feeds the watchdog. Rule-based **governance**
  is not Admiral's job — that lives in `hookd`, a separate daemon registered globally, so it
  applies to every session rather than only the ones Admiral launched.

## Layout

```
admiral/
  CLAUDE.md                 dev guide (start here when working in this repo)
  docs/                     ARCHITECTURE.md · signing.md · bridge-reconciliation.md
  Package.swift             AdmiralCore library + tests (`swift test`)
  Sources/AdmiralCore/      models · SessionManager · transcript · bridge · MCP · hooks
  Tests/                    AdmiralCoreTests (fast unit tests)
  App/                      Xcode app (xcodegen)
    Sources/                SwiftUI views · AppModel · SwiftTerm host · Intents · bridge socket
    HookHelper/             admiral-hook       (bundled tool Claude Code invokes)
    BridgeMCP/              admiral-bridge-mcp (bundled MCP relay)
    UITests/                rendered-UI tests
  scripts/                  make-signing-cert.sh · sign-app.sh · release.sh · icongen.swift · validate.sh
```

## Build & run

Requires Xcode 16/26, macOS 15+, and `xcodegen` (`brew install xcodegen`).

```bash
make test                                    # Core unit tests (fast, offline)
cd App && xcodegen generate                  # regenerate the Xcode project after file/dep changes
xcodebuild -project App/Admiral.xcodeproj -scheme Admiral -derivedDataPath App/build \
  build CODE_SIGNING_ALLOWED=NO
# rendered-UI tests:
xcodebuild test -project App/Admiral.xcodeproj -scheme Admiral -only-testing:AdmiralUITests \
  CODE_SIGNING_REQUIRED=NO
```

### Signing & install (set up once per Mac)

Admiral is signed with the **Developer ID** identity named by `$ADMIRAL_SIGN_ID` (hardened runtime) so
Keychain access and macOS privacy (TCC) grants survive rebuilds: a Team-ID signature gives Keychain items a
`teamid:<TEAM_ID>` partition that is the same for every build (a self-signed or ad-hoc build prompts after
each rebuild). Export `ADMIRAL_SIGN_ID="Developer ID Application: <Name> (<TEAM_ID>)"` in your shell rc.
On another Mac:

```bash
# 1. get the identity: Xcode > Settings > Accounts > Manage Certificates > + > "Developer ID Application"
#    (Account Holder/Admin only), OR export the cert+key as .p12 from Keychain Access on a Mac that has it
#    (strong password) and import it here.
security find-identity -v -p codesigning     # verify it's listed
scripts/release.sh                           # test + Release build + sign + install to /Applications
xcrun notarytool store-credentials admiral-notary --apple-id <id> --team-id <TEAM_ID>   # once (app-specific password)
scripts/notarize.sh                          # notarize + staple (Gatekeeper-clean)
```

The first Team-ID build asks once to access existing Keychain items — click **Always Allow**. No Developer ID?
`scripts/make-signing-cert.sh` creates the self-signed fallback `Admiral Local Signing` (works, but Keychain
prompts after every rebuild). Always build/sign via `scripts/sign-app.sh` / `scripts/release.sh` (or
`make build`); ad-hoc signing is refused unless `ADMIRAL_ALLOW_ADHOC=1`; `ADMIRAL_SIGN_ID` overrides the
identity. Optional: a Developer ID provisioning profile at `App/Admiral.provisionprofile` moves Admiral's
secrets into the data-protection keychain (an access group). Details and troubleshooting:
[`docs/signing.md`](docs/signing.md).

See [`CLAUDE.md`](CLAUDE.md) for the full developer guide and [`docs/`](docs/) for design
deep-dives.
