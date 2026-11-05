import SwiftUI
import AdmiralCore

/// Above an ACP tab's composer: why its agent is not running (with Retry = reload), and the
/// client-side queue — input that waits for the agent's turn to end.
struct AcpTabStrip: View {
    @EnvironmentObject var model: AppModel
    let session: AgentSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = session.connectError { AcpConnectErrorRow(session: session, error: error) }
            if !session.acpQueued.isEmpty { queue }
        }
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.bottom, session.connectError == nil && session.acpQueued.isEmpty ? 0 : 6)
    }

    private var queue: some View {
        let count = session.acpQueued.count
        return HStack(spacing: 6) {
            Image(systemName: "tray.full").font(.system(size: 10))
            Text("\(count) queued \u{00B7} sent when the agent's turn ends")
                .font(.system(size: 11))
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.secondaryText)
        .help(session.acpQueued.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
        .accessibilityIdentifier("acp-queue")
    }
}

/// A dead ACP tab's reason and its Retry (a reload: the agent relaunched at the same session).
struct AcpConnectErrorRow: View {
    @EnvironmentObject var model: AppModel
    let session: AgentSession
    let error: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
            Text(error)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 6)
            Button("Retry") { model.reload(session.id) }
                .controlSize(.small)
                .accessibilityIdentifier("acp-retry")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.planCardBackground))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.red.opacity(0.35)))
        .accessibilityIdentifier("acp-connect-error")
    }
}

/// The Footprint panel's top for an ACP tab: the agent, its connect error, and each Admiral
/// feature that is off on this tab with the reason the capability record gives.
struct AcpFootprintSection: View {
    @EnvironmentObject var model: AppModel
    let session: AgentSession
    let agentName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "shippingbox").font(.system(size: 10)).foregroundStyle(Theme.secondaryText)
                Text(agentName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                if let version = agentVersion {
                    Text(version).font(.system(size: 11)).foregroundStyle(Theme.secondaryText).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button("Log") { model.showACPLog(session) }
                    .buttonStyle(.link).controlSize(.small)
                    .help("Show this tab's ACP log: the JSON-RPC traffic and the agent's stderr")
            }
            if let error = session.connectError {
                AcpConnectErrorRow(session: session, error: error)
            }
            if let record = session.acpCapabilities {
                let off = AcpFeature.allCases.compactMap { f in record.reason(f).map { (f, $0) } }
                if !off.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Off on this tab")
                            .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.secondaryText)
                        ForEach(off, id: \.0) { feature, reason in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: "minus.circle")
                                    .font(.system(size: 9.5)).foregroundStyle(Theme.secondaryText)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(AgentsSettingsView.title(feature))
                                        .font(.system(size: 11.5, weight: .medium))
                                    Text(reason)
                                        .font(.system(size: 10.5)).foregroundStyle(Theme.secondaryText)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("acp-feature-off-\(feature.rawValue)")
                        }
                    }
                }
            } else if session.connectError == nil {
                Text("Connecting to the agent\u{2026}")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var agentVersion: String? {
        session.acpCapabilities?.negotiated.agentVersion.map { v in
            (session.acpCapabilities?.negotiated.agentName.map { "\($0) " } ?? "") + v
        }
    }
}
