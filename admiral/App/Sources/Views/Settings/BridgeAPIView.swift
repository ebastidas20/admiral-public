import SwiftUI
import AdmiralCore

/// Settings → Bridge & API. The API server switch mirrors the sidebar toggle (both read
/// `model.apiServerPort`, both call `toggleAPIServer`), the port applies live (a running
/// server restarts on change), and the scratch-tab reaper threshold is re-read every sweep.
struct BridgeAPIView: View {
    @EnvironmentObject private var model: AppModel
    @State private var portText = ""
    @State private var minutesText = ""
    @State private var thresholdText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SettingsCard("API server",
                             "Loopback HTTP on this port serves **both** the Anthropic-compatible "
                                + "chat API (`POST /v1/messages`) and operator MCP "
                                + "(`POST /mcp`), plus the session event stream. No API token is "
                                + "required. Cloudflare Access gates the public hostname. Browser "
                                + "requests (an `Origin` header or a non-loopback `Host`) are "
                                + "refused. Binds `127.0.0.1` only. The switch persists across "
                                + "relaunch. If the port is busy the server falls back to an "
                                + "ephemeral one.") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Serve the API + MCP", isOn: serverBinding)
                            .toggleStyle(.switch)
                            .accessibilityIdentifier("settings-api-server-toggle")
                        SettingsField(label: "Port", text: $portText,
                                      identifier: "settings-api-server-port", onCommit: commitPort)
                            .frame(maxWidth: 280)
                        Text(statusLine)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.secondaryText)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("settings-api-server-status")
                    }
                }

                SettingsCard("Trusted hosts",
                             "Extra `Host` names the API + MCP server accepts besides the built-in "
                                + "ones. A client in Docker Desktop reaches this server as "
                                + "`host.docker.internal`, which is otherwise refused as a browser "
                                + "request. Changes apply at once. A request with an `Origin` "
                                + "header is still refused.") {
                    TrustedHostsList()
                }

                SettingsCard("Group chat routing",
                             "A group message that tags nobody is scored 0 to 1 for each other "
                                + "member by a small model (haiku, on your login) reading the "
                                + "recent conversation. It reaches every member at or above the "
                                + "threshold, or the single highest scorer when none reaches it. "
                                + "Members it skips read it with their next prompt. If scoring "
                                + "fails, your message reaches everyone and an agent's reaches "
                                + "nobody. Off = untagged goes to everyone. `@name` and `@all` "
                                + "are never scored.") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Score untagged group messages", isOn: $model.groupRelevanceEnabled)
                            .toggleStyle(.switch)
                            .accessibilityIdentifier("settings-group-relevance")
                        SettingsField(label: "Threshold (0–1)", text: $thresholdText,
                                      identifier: "settings-group-relevance-threshold",
                                      onCommit: commitThreshold)
                            .frame(maxWidth: 280)
                            .disabled(!model.groupRelevanceEnabled)
                    }
                }

                SettingsCard("Scratch tabs",
                             "Small tabs at the bottom of the sidebar, not restored on relaunch. "
                                + "Sessions created through the API are always scratch tabs; MCP "
                                + "`commission` and the New form make one on request. A scratch "
                                + "tab whose goals are all done (or that has none) and that sits "
                                + "idle — not selected, not busy, no output — this long is closed "
                                + "automatically (same teardown as Delete). Right-click → Promote "
                                + "to keep one.") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Close idle scratch tabs automatically", isOn: $model.scratchAutoClose)
                            .toggleStyle(.switch)
                            .accessibilityIdentifier("settings-scratch-auto-close")
                        SettingsField(label: "Idle minutes", text: $minutesText,
                                      identifier: "settings-scratch-tab-idle", onCommit: commitMinutes)
                            .frame(maxWidth: 280)
                            .disabled(!model.scratchAutoClose)
                        Toggle("New tabs are scratch tabs by default (New form + MCP commission)",
                               isOn: $model.scratchByDefault)
                            .toggleStyle(.switch)
                            .accessibilityIdentifier("settings-scratch-by-default")
                    }
                }

                SettingsCard("PHI-redacted output",
                             "For a tab with an output schema, each round's structured output "
                                + "(`set_structured_output`) has every string sent to Sonnet with "
                                + "PHI replaced by [REDACTED], and the session event stream "
                                + "(`/sessions/<callsign>/events`) sends only that copy as the "
                                + "`output` event, with `\"redacted\": true`. If Sonnet fails, the "
                                + "round goes out failed with no result. The screen, the "
                                + "transcript and the other events keep the full text. One Sonnet "
                                + "call per string per round, on the tab's own login.") {
                    Toggle("Redact structured output in the event stream", isOn: $model.redactReplies)
                        .toggleStyle(.switch)
                        .accessibilityIdentifier("settings-redact-replies")
                }

                SettingsCard("Bridge socket",
                             "The Unix socket serving this instance's bridge (each session's "
                                + "injected `bridge` MCP relay connects to it). Fixed per "
                                + "instance/profile — shown for debugging.") {
                    Text(model.bridgeSocketPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.secondaryText)
                        .textSelection(.enabled)
                }
            }
            .padding(20)
        }
        .onAppear {
            portText = String(model.apiServerPreferredPort)
            minutesText = String(model.scratchTabIdleMinutes)
            thresholdText = String(model.groupRelevanceThreshold)
        }
    }

    /// The switch mirrors live server state, so a sidebar/palette toggle updates it too.
    private var serverBinding: Binding<Bool> {
        Binding(get: { model.apiServerPort != nil }, set: { _ in model.toggleAPIServer() })
    }

    private var statusLine: String {
        guard let port = model.apiServerPort else { return "Stopped." }
        var line = "Serving http://127.0.0.1:\(port)  —  /v1/messages + /mcp"
        if port != model.apiServerPreferredPort {
            line += "  — port \(model.apiServerPreferredPort) was busy, using an ephemeral port"
        }
        return line
    }

    /// Invalid input reverts to the stored value rather than silently persisting garbage.
    private func commitPort() {
        guard let port = UInt16(portText.trimmingCharacters(in: .whitespaces)), port > 0 else {
            portText = String(model.apiServerPreferredPort)
            return
        }
        model.apiServerPreferredPort = port  // didSet persists + restarts a running server
    }

    private func commitThreshold() {
        guard let value = Double(thresholdText.trimmingCharacters(in: .whitespaces)), (0...1).contains(value) else {
            thresholdText = String(model.groupRelevanceThreshold)
            return
        }
        model.groupRelevanceThreshold = value
    }

    private func commitMinutes() {
        guard let minutes = Int(minutesText.trimmingCharacters(in: .whitespaces)), minutes >= 1 else {
            minutesText = String(model.scratchTabIdleMinutes)
            return
        }
        model.scratchTabIdleMinutes = minutes
    }
}
