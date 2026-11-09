import SwiftUI
import AdmiralCore

/// The PR status chips (open · merge/blocked · approvals · checks), shared by the status bar
/// and the touched-repos panel. The caller supplies a `confirmingMerge` binding (the model's
/// on the status bar, so ⇧⌘M can drive it; a local @State in panel rows) and the merge action.
struct PRChipsView: View {
    let pr: PRStatus
    @Binding var confirmingMerge: Bool
    var onMerge: () -> Void = {}
    @FocusState private var confirmFocused: Bool
    @Environment(\.openURL) private var openURL

    private let green = Theme.checkGreen
    private let red = Color(nsColor: .systemRed)

    var body: some View {
        FlowLayout(spacing: 8, lineSpacing: 8) {
            Button { if let url = URL(string: pr.url) { openURL(url) } } label: {
                coloredChip("link", "PR #\(pr.number)", Theme.accent)
            }
            .buttonStyle(.plain)
            .help("Open PR #\(pr.number) in browser")

            if pr.isMerged {
                coloredChip("checkmark.seal.fill", "Merged", Theme.accent)
            } else {
                if pr.canMerge {
                    Button { confirmingMerge = true } label: {
                        coloredChip("arrow.triangle.merge", "Merge", green)
                    }
                    .buttonStyle(.plain)
                    .help("Merge PR #\(pr.number)")
                    .popover(isPresented: $confirmingMerge, arrowEdge: .top) { mergePopover }
                } else {
                    coloredChip("lock.fill", "Blocked", Theme.secondaryText)
                        .help("Blocked — needs required approvals/checks before it can merge")
                }
                coloredChip("checkmark.circle.fill", "\(pr.approvals)",
                            pr.approvals > 0 ? green : Theme.secondaryText)
                if pr.checksPassed + pr.checksRunning + pr.checksFailed > 0 {
                    coloredChip("checklist", checksText, checksColor)
                }
            }
        }
    }

    private var checksText: String {
        var parts: [String] = []
        if pr.checksPassed > 0 { parts.append("\(pr.checksPassed)✓") }
        if pr.checksRunning > 0 { parts.append("\(pr.checksRunning)•") }
        if pr.checksFailed > 0 { parts.append("\(pr.checksFailed)✗") }
        return parts.isEmpty ? "no checks" : parts.joined(separator: " ")
    }

    private var checksColor: Color {
        if pr.checksFailed > 0 { return red }
        if pr.checksRunning > 0 { return Theme.busyAmber }
        if pr.checksPassed > 0 { return green }
        return Theme.secondaryText
    }

    @ViewBuilder
    private var mergePopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Merge PR #\(pr.number)?").font(.system(size: 12, weight: .semibold))
            if !pr.title.isEmpty {
                Text(pr.title).font(.system(size: 11)).foregroundStyle(Theme.secondaryText).lineLimit(2)
            }
            HStack {
                Button("Open PR") {
                    if let url = URL(string: pr.url) { openURL(url) }
                    confirmingMerge = false
                }.buttonStyle(.link)
                Spacer()
                Button("Cancel") { confirmingMerge = false }
                    .keyboardShortcut(.cancelAction)
                    .focused($confirmFocused)
                Button("Merge") { confirmingMerge = false; onMerge() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(green)
            }
        }
        .padding(14).frame(width: 290)
        .onAppear { confirmFocused = true }
        .onExitCommand { confirmingMerge = false }
    }

    private func coloredChip(_ icon: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Rectangle().fill(color.opacity(0.15)))
    }
}
