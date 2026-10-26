import AdmiralCore

// admiral-client-mcp — the `client` MCP server bundled into Admiral and injected only
// on API tool tabs (`POST /v1/messages` with `tools`). Claude Code speaks MCP on stdio;
// a `tools/call` is parked on this instance's client-tool socket until the Messages
// client posts the matching `tool_result`. The binary does not execute the tool.

ClientToolProcess.main()
