# Client tools on `POST /v1/messages`

An Anthropic Messages client (LangGraph, or a small HTTP script) can send `tools` on
`POST /v1/messages`. Admiral commissions an API scratch tab whose Claude Code process
sees those tools on an MCP server named `client`. When Claude calls one, Admiral does
not run it. The call is parked, the HTTP response is an assistant message with
`stop_reason: "tool_use"`, and the client runs the tool. The next request carries the
`tool_result` blocks. Admiral hands them to the parked calls and Claude continues the
same turn.

The catalog is advertised under the real tool names (`get_lucky_number`, not one
shared `client_tool`). `tools/list` returns each name with its `inputSchema`. The MCP
server sets `capabilities.tools.listChanged`, and the process emits
`notifications/tools/list_changed` when the catalog file's mtime changes. The catalog
is written before the tab is spawned, so the first `tools/list` is already right even
if a Claude Code build only honors `list_changed` on the newer protocol stream.

## Parallel parks

One assistant message may contain several `tool_use` blocks. The `client` MCP process
keeps a single connection to Admiral's client-tool socket and keeps reading stdin while
a `tools/call` is parked, so every call in the message is registered before any of them
returns. Admiral correlates each park to a transcript `toolu_…` id by normalized name
(`mcp__client__` stripped) and canonical JSON input, oldest park first when the same
tool is called twice. The HTTP response uses those transcript ids and the unprefixed
names.

The continuation has to post every outstanding id in one request, with no user text
beside the `tool_result` blocks. A subset, an extra id, or plain text is `400`. The
whole set is fulfilled together. A matching continuation is accepted while the tab is
still busy. Plain text, operator inject, and `send_keys` are refused until the results
arrive (`400` on the HTTP route, not `529`).

## What an API tool tab launches with

Only a request that creates the scratch tab (`ADMIRAL_SESSION_ID` plus `ADMIRAL_CWD`,
no `ADMIRAL_TAB_NAME`) can commission client tools. The first `model` that maps onto a
`ScheduleModel` alias is passed as `claude --model`. `haiku`, `claude-haiku`,
`claude-haiku-4-5`, and `claude-3-5-haiku-latest` all map to `haiku`. An id that names
no alias passes no `--model` flag. The HTTP response still echoes the request's
`model` string. Later requests do not relaunch the process, so the first model sticks.

The tab is not an interactive session:

- `--tools ""` removes built-in tools. `--strict-mcp-config` loads only Admiral's MCP
  config. `--permission-mode bypassPermissions` skips permission dialogs. Settings set
  that same mode and do not name the removed tools in `permissions.deny` — Claude Code
  warns that each such rule matches no tool.
- The `client` server timeout is 600000 ms, and the process gets `MCP_TOOL_TIMEOUT`
  to the same value.
- `PreToolUse` matches every tool and denies anything that is not `mcp__client__*`
  (including the bridge tools). `UserPromptSubmit` tells the model the catalog instead
  of the goals reminder.
- A forced `tool_choice` is still structured output and cannot be combined with client
  tools. `tool_choice` `auto` (or omitted) with `tools` is this path.

Interactive tabs are unchanged when `tools` is absent.

## Try it against Haiku on port 4141

Admiral listens on `127.0.0.1:4141`. A LangGraph client can drive it the same way;
this is the same loop, as a single HTTP script: one bogus
tool, `get_lucky_number`, that always returns `7`. The `model` is a Haiku alias so the
scratch tab actually launches Haiku.

```bash
SID=$(uuidgen | tr 'A-Z' 'a-z')
URL=http://127.0.0.1:4141/v1/messages
HDR=(-H "content-type: application/json" -H "anthropic-version: 2023-06-01" \
     -H "admiral_session_id: $SID" -H "admiral_cwd: $PWD")

# 1. Claude should answer with a tool_use for get_lucky_number.
curl -s "$URL" "${HDR[@]}" -d @- <<'JSON'
{
  "model": "claude-haiku-4-5",
  "max_tokens": 256,
  "tools": [{
    "name": "get_lucky_number",
    "description": "Return the lucky number. It is always 7.",
    "input_schema": {"type": "object", "properties": {}}
  }],
  "messages": [{
    "role": "user",
    "content": "Call get_lucky_number once, then tell me the number it returned."
  }]
}
JSON

# 2. Post the tool_result for the toolu_… id from that response (no user text).
# 3. The next response is the assistant's text, and it should mention 7.
```

A continuation body replaces `messages` with the prior user message, the assistant
`tool_use` blocks, and one user message whose content is only `tool_result` blocks:

```json
{
  "role": "user",
  "content": [{
    "type": "tool_result",
    "tool_use_id": "toolu_…",
    "content": "7"
  }]
}
```

Send every id from the assistant message in that one request. The same `SID` keeps
the tab, and with it the Haiku process from the first request.

## Follow-ups

- A `tools/call` that arrives after the HTTP turn has already failed has no timer of
  its own. The socket does fail that connection's parks when the MCP process
  disconnects. A park whose HTTP turn ended another way stays until the session is
  deleted.
- Claude Code's v2 runtime may only apply `list_changed` on the 2026 protocol stream.
  The catalog is on disk before spawn, so the first list is still the real names.
- API tool tabs do not get the goals reminder. The first request's model is fixed for
  the life of the process. Structured output and client tools cannot be combined.
- `--tools ""` is what current Claude Code uses to drop built-ins. The `PreToolUse`
  deny is the backstop if a build ignores the flag. Those names are not also listed
  in `permissions.deny`.
