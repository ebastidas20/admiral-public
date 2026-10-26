# Signing & install: the local signing cert

Admiral is always signed with a **stable certificate**, never ad-hoc: the
`Developer ID Application: <Name> (<TEAM_ID>)` cert when the Mac has one (hardened runtime +
timestamp; needed for prompt-free Keychain access and for notarization, see below), else the
self-signed `Admiral Local Signing` cert. Set it up once
per Mac, then build and install only through the signing scripts.

## Fallback setup: the self-signed cert (only if the Mac has no Developer ID)

Preferred: Developer ID — see "Setting up Developer ID signing on ANOTHER machine" below. This
self-signed cert has a stable DR but no Team ID, so Keychain items prompt after every rebuild.


```bash
scripts/make-signing-cert.sh                 # once per Mac
security find-identity -v -p codesigning     # verify: should list "Admiral Local Signing"
```

`make-signing-cert.sh` creates a **self-signed** code-signing certificate named
`Admiral Local Signing` in the **login keychain** and trusts it for code signing. It needs no
Apple Developer account, the private key never leaves that Mac, and it is **per-Mac** — each
Mac makes its own (the script is idempotent: re-running it when the cert exists does nothing).

If `find-identity` doesn't list it as valid, signing still works (see Troubleshooting); to get
it listed, open Keychain Access → the certificate → Trust → Code Signing: **Always Trust**.

## Building and installing

Always build and sign via the scripts — never call `codesign` yourself:

```bash
make build                          # Debug build + scripts/sign-app.sh
scripts/sign-app.sh path/to/Admiral.app   # sign an existing bundle (helpers first, then the app)
scripts/release.sh                  # swift test + Release build + sign + install to /Applications
scripts/release.sh 1.1.0            # ...and stamp MARKETING_VERSION = 1.1.0 (MAJOR.MINOR.PATCH only)
```

**Never** run `codesign --force --deep --sign - …` (ad-hoc) on Admiral.

## Why

macOS files Keychain "Always Allow" decisions and TCC privacy grants (App Data, Automation,
Files & Folders) under the app's **designated requirement** (DR).

- Signed with the local cert, the DR is
  `identifier "com.pedro.admiral" and certificate leaf = H"<cert hash>"` — identical on every
  rebuild, so a grant given once is kept.
- **Ad-hoc** signing has no DR; macOS falls back to the executable's cdhash, which changes on
  every build. Each rebuild looks like a different app, so Keychain and TCC prompt again.

## Optional: `ADMIRAL_SIGN_ID`

`ADMIRAL_SIGN_ID` overrides the identity for `sign-app.sh`. `make-signing-cert.sh` ignores it and
always creates `Admiral Local Signing`, so a Mac without the real Developer ID never gets a
self-signed certificate wearing a `Developer ID Application: …` name. The key is imported with
`-T /usr/bin/codesign`: codesign may use it without a prompt, no other process may.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `✗ no signing identity found` (sign-app.sh exits 1) | Neither the Developer ID nor `Admiral Local Signing` exists on this Mac (or `ADMIRAL_SIGN_ID` names one that doesn't). Install the Developer ID cert, or run `scripts/make-signing-cert.sh`, confirm with `security find-identity -v -p codesigning`, then rebuild via `scripts/sign-app.sh` / `scripts/release.sh`. |
| Keychain/permission prompts again after a rebuild | The build was ad-hoc signed (no cert at build time, or someone ran `codesign --sign -`), so the DR changed. Fix the cert, re-sign with `scripts/sign-app.sh`. |
| Keychain prompts after every rebuild even though the DR is stable | The build was signed with the self-signed cert (no Team ID → `cdhash:` partition). Sign with the Developer ID identity (`security find-identity -v -p codesigning`) via `scripts/sign-app.sh`; the next launch prompts once (Always Allow). |
| Prompts once after switching from ad-hoc to the cert, or after recreating the cert | The DR changed one time. Click **Always Allow** once (and re-grant the TCC permissions once); it then sticks across rebuilds. |

Check what a build actually carries: `codesign -d -r- /Applications/Admiral.app` — it should
print `identifier "com.pedro.admiral" and certificate leaf = H"…"`, not a bare cdhash.

## Developer ID, notarization and Gatekeeper

`scripts/sign-app.sh` signs with the Developer ID cert and hardened runtime, so
`spctl -a -vv /Applications/Admiral.app` reports `source=Unnotarized Developer ID,
origin=Developer ID Application: <Name> (<TEAM_ID>)` (rejected only because it is not
notarized yet). Locally built and copied apps carry no quarantine flag and launch regardless.

To make the app **Gatekeeper-clean** (`accepted, source=Notarized Developer ID`) and portable:

1. One time, create notary credentials (needs an app-specific password from appleid.apple.com):
   ```
   xcrun notarytool store-credentials admiral-notary --apple-id <apple id> --team-id <TEAM_ID>
   ```
   (it prompts for the password and saves a keychain profile named `admiral-notary`).
2. After `scripts/release.sh` (or `scripts/sign-app.sh <app>`): `scripts/notarize.sh [app]`
   zips with `ditto`, runs `xcrun notarytool submit --wait`, then `xcrun stapler staple` and validates.
   It refuses non-Developer-ID or non-hardened-runtime bundles.

## Setting up Developer ID signing on ANOTHER machine

Team ID: **<TEAM_ID>**. Identity name: `Developer ID Application: <Name> (<TEAM_ID>)`.
Keychain access survives rebuilds **only when every build is signed by the same team** (the item's
partition list is `teamid:<TEAM_ID>`); a build signed by another team, the self-signed fallback, or
ad-hoc is a different client and prompts again.

**1. Get the signing identity on that Mac — pick one:**

- **(a) Create it in Xcode** (only the team's Account Holder / Admin can create Developer ID
  certificates): Xcode → Settings → Accounts → sign in with the paid team's Apple ID → select the team →
  **Manage Certificates…** → **+** → **Developer ID Application**.
- **(b) Move this Mac's cert + private key** (works for any team member who has the `.p12`): on this Mac,
  Keychain Access → login → My Certificates → *Developer ID Application: <Name> (<TEAM_ID>)*
  (expand it so the private key is included) → right-click → **Export…** → `.p12`, with a **strong
  password**. Transfer it securely (not the repo, not cloud notes), double-click it on the other Mac to import
  into the login keychain, then delete the `.p12`. Also import Apple's *Developer ID Certification Authority*
  intermediate if `find-identity` calls the chain untrusted (Xcode installs it automatically).

**2. Verify** (must list it as valid):

```bash
security find-identity -v -p codesigning     # → "Developer ID Application: <Name> (<TEAM_ID>)"
```

`scripts/sign-app.sh` uses it once your shell rc exports it:
`export ADMIRAL_SIGN_ID="Developer ID Application: <Name> (<TEAM_ID>)"` (the exact identity name or
hash). Build from a shell that has read the rc.

**3. Build, install, notarize:**

```bash
scripts/release.sh                 # swift test + Release build + sign (hardened runtime) + install
scripts/notarize.sh                # zip → notarytool submit --wait → stapler staple (see step 4)
spctl -a -vv /Applications/Admiral.app    # → accepted, source=Notarized Developer ID
```

**4. One-time notary credentials per Mac** (app-specific password from appleid.apple.com → Sign-In and
Security → App-Specific Passwords; never your Apple ID password):

```bash
xcrun notarytool store-credentials admiral-notary --apple-id <apple id> --team-id <TEAM_ID>
```

This stores a keychain profile named `admiral-notary` (override with `ADMIRAL_NOTARY_PROFILE`).
Alternatively skip building there: copy over the already **notarized + stapled** `Admiral.app`
(`ditto -c -k --keepParent Admiral.app Admiral.zip`); a downloaded copy is quarantined but passes Gatekeeper
because it is notarized.

**5. First launch of the first Team-ID-signed build.** Existing Keychain items made by an older
(self-signed / cdhash-bound) build prompt **once**: click **Always Allow**. That adds
`teamid:<TEAM_ID>` to the item's partition list. From then on rebuilds do not prompt. On a Mac with
no previous Admiral items nothing prompts at all — a Team-ID build's new items get the team partition.
TCC grants (Automation, Files & Folders) are asked once more, because the designated requirement changed.

**Fallback — no Developer ID available:** run `scripts/make-signing-cert.sh` (creates the self-signed
`Admiral Local Signing`; `sign-app.sh` then uses it). The designated requirement is stable but there is no
Team ID, so Keychain items stay bound to each build's cdhash and **prompt after every rebuild** (the
the API does not wait on that prompt; the port is unaffected).
Ad-hoc signing is refused unless `ADMIRAL_ALLOW_ADHOC=1`. An MDM-managed Mac that rejects self-signed
certs needs the notarized Developer ID build.

## Keychain access that survives rebuilds (Team-ID signing)

**Problem.** Admiral's Keychain items (operator token `com.pedro.admiral.operator-mcp`, Jira items
`com.pedro.admiral.tickets.jira`) live in the legacy login keychain. When an item is created,
securityd stamps a **partition list** into its ACL: `teamid:<TEAM>` if the creator's signature has a
Team ID, else `cdhash:<hash>`. A self-signed cert has **no Team ID**, so the partition is the
build's cdhash — which changes on every rebuild. The designated requirement being stable does
not help: securityd logs `ACL partition mismatch: client cdhash:… ACL (cdhash:…)` and shows
"Admiral wants to use your confidential information".

**Findings (probe item `com.pedro.admiral.probe`, a cert-signed tool rebuilt with a different cdhash):**

| experiment | result |
|---|---|
| default `SecItemAdd`, rebuild with same cert/identifier/path | **prompt** (`ACL partition mismatch`); "Always Allow" just appends the new cdhash to the list, so every build prompts once |
| `SecAccessCreate` + trusted-app list (`SecTrustedApplicationCreateFromPath`) | ACL entry lists the app (that check is not the problem) but securityd **still adds `cdhash:` to the partition list** → still prompts. The trusted-app list alone does not help |
| change the partition list afterwards (`SecKeychainItemSetAccess`, `security set-generic-password-partition-list`) | needs the **login-keychain password** (ChangeACL prompt) — not available to the app |
| partition list set at creation / wildcard-ish lists (`apple-tool:,apple:`, empty list) | not proven usable for a non-Apple client; testing was stopped |
| sign with a Team-ID identity (`Developer ID Application` / `Apple Development`; tested with both) | signing works with no prompt; the code carries a Team ID, so securityd uses `teamid:<TEAM_ID>` as the client's partition. **Verified on the real operator-token item**: after one "Always Allow" the partition list gained `teamid:<TEAM_ID>`, and a second rebuild (different cdhash, same team) read the token with **no prompt** (securityd logged no `ACL partition mismatch`, the token read succeeded within 3 s; the API no longer checks that token) |
| data-protection keychain (`kSecUseDataProtectionKeychain`) | needs `keychain-access-groups`, a restricted entitlement. Probed 2026-10-05 with a Developer ID binary: an app-group entitlement alone gets `errSecMissingEntitlement` (-34018); `keychain-access-groups` without a profile is killed at launch. Works with a Developer ID provisioning profile — see "Keychain access group" below |
| plain `SecItemAdd` from a Team-ID build (no `SecAccess`) | re-probed 2026-10-05: item added by one build, then read, updated and deleted by a rebuilt one (different cdhash, same identifier + team) with keychain UI disabled — all succeed, so no prompt was needed |

**What Admiral does now** (`AdmiralCore/Support/Keychain.swift`).

- `scripts/sign-app.sh` picks the identity: `$ADMIRAL_SIGN_ID` (your Developer ID, exported in
  your shell rc) → `Admiral Local Signing`; it **fails** rather than falling back to ad-hoc
  (unless `ADMIRAL_ALLOW_ADHOC=1`). Developer ID builds get `--options runtime --timestamp` (helpers
  too); the runtime needs no entitlements (checked by launching the signed app: PTYs/shells, API server,
  Keychain all work) — the only one Admiral may claim is the keychain group, and only with a profile.
  `ADMIRAL_NO_TIMESTAMP=1` signs offline. The designated requirement becomes
  `identifier "com.pedro.admiral" and anchor apple generic and … certificate leaf[subject.OU] = <TEAM_ID>`
  — stable across rebuilds *and* certificate renewals.
- Without a profile, items live in the login keychain, created with a plain `SecItemAdd` (this device
  only, after first unlock). From a Team-ID build that gives partition `teamid:<TEAM>` and an ACL that
  trusts the app's designated requirement, so every rebuild by the same team reads them silently. No
  `SecAccess` trusted-app lists or partition fix-ups any more.
- Items an older cdhash-bound build made prompt **once** on the first Team-ID build: click **Always
  Allow** (that appends `teamid:<TEAM_ID>` to the partition list).
- A build without a Team ID (self-signed fallback, ad-hoc) prompts after each rebuild.
- Switching the signing identity changes the app's designated requirement once → TCC grants
  (Automation, Files & Folders, …) are asked for again once, then stick.

## Keychain access group (provisioning profile)

With a Developer ID provisioning profile for `com.pedro.admiral` on the Mac, `scripts/sign-app.sh` embeds
it (`Contents/embedded.provisionprofile`) and signs the app with entitlements built from
`App/Admiral.entitlements`. That file is a template: the script reads the team id from the profile
(`Entitlements:com.apple.developer.team-identifier`), checks the profile's application identifier is
`<TEAM_ID>.com.pedro.admiral`, and substitutes it for every `__TEAM_ID__`, so the signed app claims
`keychain-access-groups` = `<TEAM_ID>.com.pedro.admiral` and no team id lives in the repo. `Keychain.accessGroup` reads that entitlement
at launch, and every item then lives in the data-protection keychain under the group: no ACLs, no partition
lists, no prompts — the same items a sandboxed App Store build uses. Without a profile nothing is claimed
and the login keychain is used as above.

**Moving in.** The first launch of a profile-signed build moves each item out of the login keychain
(`Keychain.moveFromLoginKeychain`) before anything reads it: the operator token in
`OperatorTokenStore.resolve`, the Jira items before `TicketsAuthStore`'s first read. It copies, reads back,
and only then deletes the login-keychain item; if the group already holds a different value, the group's
wins and the old item is kept. A failed move never mints a new operator token. The API does not
need that token; resolution retries in the background until the move finishes.

**Set up, once per Mac** (the profile is gitignored, like the cert):

1. developer.apple.com → Certificates, Identifiers & Profiles → Identifiers → **+** → App IDs → App →
   explicit Bundle ID `com.pedro.admiral` (no capabilities to tick).
2. Profiles → **+** → Distribution → **Developer ID** → App ID `com.pedro.admiral` → the Developer ID
   Application certificate → name it → **Download**.
3. Save it as `admiral/App/Admiral.provisionprofile` (or point `ADMIRAL_PROVISIONING_PROFILE` at it), then
   `scripts/release.sh`. `sign-app.sh` prints `provisioning profile: … → keychain access group`; confirm with
   `codesign -d --entitlements - /Applications/Admiral.app`.

`sign-app.sh` refuses a profile made for another App ID and ignores one when the identity isn't Developer ID.

## API server and the Keychain

The API server (`:4141`) binds immediately at launch and never waits on the Keychain. `POST /mcp`,
`POST /v1/messages` and `/sessions/<callsign>/events` do not require an operator token. A missing
or wrong `Authorization` / `x-api-key` is not rejected. Cloudflare Access gates the public hostname.
A pending Keychain prompt cannot take the API down or push it to another port.
`AnthropicHTTPServer.stop()` now waits for the listen socket to actually close and `start()` retries
the preferred port briefly on `EADDRINUSE` — a stop/start restart used to race the old listener's
asynchronous close and fall back to a random port.

## Operator token: Keychain only, not required by the API

`POST /mcp`, `POST /v1/messages` and `/sessions/<callsign>/events` succeed without
`Authorization: Bearer` or `x-api-key`. Requests carrying an `Origin` header or a
non-loopback `Host` are still refused (403). A token is still kept **only in the
Keychain** (generic password, service `com.pedro.admiral.operator-mcp`, account `token`,
AfterFirstUnlockThisDeviceOnly) so a legacy token file can be migrated. There is no token file
after that migration. A well-formed token is `adm_` + 32 lowercase hex characters. Settings does
not show it, and nothing fails if it is missing.

At launch Admiral resolves it off the main thread, so a pending access prompt
can never hang launch, the UI, or the API. Two waits apply:

- **Steady-state reads: 2 s.** Short, so nothing sits behind a prompt.
- **First-run / migration calls: up to 120 s, in the background.** A human may have to answer a
  Keychain access prompt. The API server does not wait for this.
- **Automatic retry.** If the 120 s wait still expires, Admiral re-runs the resolution every 15 s
  for about 5 minutes, so clicking **Allow** late takes effect without any other action. A relaunch
  also re-runs it.

| Keychain | what happens |
|----------|--------------|
| well-formed | kept |
| no item (or unusable value) | a new token is minted and stored in the Keychain — nothing is written to disk |
| timeout / error | nothing is minted or overwritten; the API keeps serving. Resolution retries in the background |

Settings → Bridge & API has no token controls.

### Migration from the old token file (automatic at startup)

Older builds kept the token in `~/Library/Application Support/Admiral/operator-mcp-token.txt`.
If that file exists, `OperatorTokenStore.migrateLegacyTokenFile` (one function, marked temporary,
safe to delete once no install has the file) handles it:

**End state: the Keychain holds the file's value (verified by an in-process read-back) and the file
is gone. If the Keychain and the file differ, the FILE value wins.**

| Keychain | what happens |
|----------|--------------|
| equals the file | the file is deleted |
| missing, malformed, **or a different value** | the file value overwrites the item (`SecItemUpdate`; if the update fails on the item's ACL, the item is deleted and re-added so the new item is owned by the current build), is read back in-process, and **only if the read-back equals the file value** the file is deleted |
| prompt unanswered (timeout) | file kept; retried automatically (see above) and on next launch |
| write error / read-back mismatch | file kept; retried on next launch |

There is no "out of sync" limbo and no choice to make in Settings.

The file is never deleted unless the in-process equality check passed. The API does not read the
token either way. Until the Keychain answers, the file is left in place; the server is already up.

### Recovery

- **Keychain item lost** (deleted, new login keychain, new Mac): on next launch Admiral mints a
  **new** token and stores it. Clients do not need it.
- **Read the stored token** (optional; this may show a Keychain access prompt, so don't run it
  from scripts):

```
security find-generic-password -s com.pedro.admiral.operator-mcp -a token -w
```

- **Start over**: `security delete-generic-password -s com.pedro.admiral.operator-mcp -a token`,
  then relaunch (a new token is minted). The API does not change.
- **Access prompt after a rebuild.** (Only with a Team-ID-less build — see "Keychain access that
  survives rebuilds".) The Keychain item's ACL partition is the build's cdhash (a
  self-signed cert has no team ID), so the first Keychain read after every new build can show a
  "Admiral wants to use … in your keychain" dialog (securityd logs `ACL partition mismatch`).
  A pending legacy-file migration waits for your answer in the background (up to 120 s, then
  retries every 15 s for ~5 min). The API is already serving and does not need the token.
  Click **Always Allow** and the migration completes by itself; a relaunch forces it. After a
  steady-state read times out (no legacy file) the same retry applies.
