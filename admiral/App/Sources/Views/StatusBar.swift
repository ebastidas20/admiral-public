import SwiftUI
import AdmiralCore

/// The bottom status bar: cwd · branch · team · todo-count. The team chip opens a
/// popover listing the other sessions on that team (excludes this one).
struct StatusBar: View {
    let session: AgentSession
    let conversation: Conversation
    /// Other sessions on this session's team (computed by the parent, which has the model).
    var teammates: [AgentSession] = []
    /// Merge-readiness of this session's PR (from the model); nil hides the PR chips.
    var prStatus: PRStatus?
    /// Invoked to merge the PR (after the confirm).
    var onMerge: () -> Void = {}
    /// Drives the merge-confirm popover — owned by the model so the ⇧⌘M command can open it too.
    @Binding var confirmingMerge: Bool
    @State private var showingTeam = false

    var body: some View {
        HStack(spacing: 8) {
            chip("folder", shortCwd)
            if let branch = session.gitBranch {
                chip("arrow.triangle.branch", branch)
            }
            // A tab on a third-party endpoint is otherwise indistinguishable from one on
            // Anthropic. The tag says that it is; hovering names the config.
            // An ACP tab's agent, in the provider's slot (an ACP tab never has a CC Switch one).
            if case let .acp(agentName) = session.backend {
                chip("shippingbox", agentName)
                    .help("Runs on the ACP agent \u{201C}\(agentName)\u{201D}")
                    .accessibilityIdentifier("status-acp-agent")
            }
            if let providerName = session.providerName {
                chip("cpu", "Custom Model")
                    .help(providerProvenance(providerName))
                    .accessibilityIdentifier("status-custom-model")
            }
            if let team = session.teamName, !team.isEmpty {
                Button { showingTeam = true } label: { chip("person.2.fill", team) }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showingTeam, arrowEdge: .top) { teamPopover(team) }
            }
            if let plan = conversation.plan {
                chip("list.bullet", "\(plan.progress.done)/\(plan.progress.total)")
            }
            if let pr = prStatus {
                PRChipsView(pr: pr, confirmingMerge: $confirmingMerge, onMerge: onMerge)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.contentBackground)
    }

    @ViewBuilder
    private func teamPopover(_ team: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Team \(team)").font(.system(size: 12, weight: .semibold))
            if teammates.isEmpty {
                Text("No other members").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
            } else {
                ForEach(teammates) { m in
                    HStack(spacing: 6) {
                        Circle().fill(Theme.statusColor(m.status)).frame(width: 6, height: 6)
                        Text(m.displayTitle).font(.system(size: 12)).foregroundStyle(Theme.primaryText)
                    }
                }
            }
        }
        .padding(12)
        .frame(minWidth: 180, alignment: .leading)
    }

    private var shortCwd: String {
        (session.cwd as NSString).abbreviatingWithTildeInPath
    }

    /// Names the CC Switch config this session launched on. Deliberately NOT a catalog
    /// lookup: this is computed on every render, and reading CC Switch's database (which
    /// can mean copying it) per frame to restate an endpoint would be a poor trade.
    private func providerProvenance(_ name: String) -> String {
        "Custom model — \(name)"
    }

    private func chip(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text).font(.system(size: 11))
        }
        .foregroundStyle(Theme.secondaryText)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Rectangle().fill(Theme.chipBackground))
    }
}
