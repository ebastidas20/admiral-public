import SwiftUI
import AdmiralCore

/// One tool call in an ACP tab's Chat: a compact row (what kind of call, what it did, how it
/// ended) that opens on a click to show what it produced — a command's output, or an edit's diff.
/// Collapsed by default; a call with nothing to show doesn't open.
struct ToolCard: View {
    let tool: ChatTool

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded, hasDetail {
                Rectangle().fill(Theme.bubbleBorder).frame(height: 1)
                detail
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.planCardBackground))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.bubbleBorder))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.leading, 34)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("acp-tool-\(tool.status.rawValue)")
    }

    private var hasDetail: Bool {
        switch tool.detail {
        case .none: false
        case let .output(text): !text.isEmpty
        case .diff: true
        }
    }

    private var header: some View {
        Button {
            withAnimation(.easeOut(duration: 0.12)) { expanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: Self.symbol(for: tool.name))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 16)
                Text(tool.title)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(tool.title)
                Spacer(minLength: 6)
                if hasDetail {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.secondaryText)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                ToolStatusMark(status: tool.status)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!hasDetail)
        .accessibilityLabel("\(tool.name): \(tool.title)")
        .accessibilityValue(tool.status.rawValue)
    }

    @ViewBuilder private var detail: some View {
        switch tool.detail {
        case .none: EmptyView()
        case let .output(text): ToolOutputView(text: text)
        case let .diff(path, hunks, created): ToolDiffView(path: path, hunks: hunks, created: created)
        }
    }

    /// The kind icon, by the Claude tool name.
    static func symbol(for name: String) -> String {
        switch name {
        case "Bash": "terminal"
        case "Edit", "Write": "pencil"
        case "Read": "doc.text"
        case "Grep": "magnifyingglass"
        case "WebFetch": "globe"
        default: "wrench.and.screwdriver"
        }
    }
}

/// Running, done or failed: a spinner, a green check, a red cross.
private struct ToolStatusMark: View {
    let status: ChatTool.Status

    var body: some View {
        Group {
            switch status {
            case .running:
                ProgressView().controlSize(.mini)
            case .completed:
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.checkGreen)
            case .failed:
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.failureRed)
            }
        }
        .frame(width: 14, height: 14)
    }
}

/// What a call printed, mono: up to 12 lines show in full, more scroll inside a 12-line box.
private struct ToolOutputView: View {
    let text: String

    @State private var copied = false
    @State private var hovering = false

    private static let maxLines = 12
    private static let lineHeight: CGFloat = 15

    private var lineCount: Int { text.split(separator: "\n", omittingEmptySubsequences: false).count }

    var body: some View {
        Group {
            if lineCount > Self.maxLines {
                ScrollView(.vertical) { content }
                    .frame(height: CGFloat(Self.maxLines) * Self.lineHeight + 16)
            } else {
                content
            }
        }
        .overlay(alignment: .topTrailing) {
            CopyControl(label: "Copy output", copied: $copied) { ChatClipboard.copy(text) }
                .opacity(hovering || copied ? 1 : 0)
                .padding(4)
        }
        .onHover { hovering = $0 }
    }

    private var content: some View {
        Text(text)
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(Theme.primaryText)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 8)
    }
}

/// An edit's diff: the path (with a badge for a new file), then each hunk's lines with both
/// texts' line numbers in the gutter. Long diffs stop at 40 lines until "Show all".
private struct ToolDiffView: View {
    let path: String
    let hunks: [LineDiff.Hunk]
    let created: Bool

    @State private var showAll = false

    private static let collapsedLines = 40

    var body: some View {
        let rows = LineDiff.numbered(hunks)
        let visible = showAll ? rows : Array(rows.prefix(Self.collapsedLines))
        let gutter = gutterWidth(rows)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(path)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path)
                if created {
                    Text("New file")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.checkGreen)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.diffAdded))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)

            ForEach(Array(visible.enumerated()), id: \.offset) { index, row in
                if index > 0, row.hunk != visible[index - 1].hunk { hunkGap(gutter) }
                DiffRow(row: row, gutter: gutter)
            }

            if rows.count > visible.count {
                Button("Show all \(rows.count) lines") { showAll = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 10).padding(.vertical, 6)
            }
        }
        .padding(.bottom, 4)
    }

    /// Wide enough for the biggest number either side shows.
    private func gutterWidth(_ rows: [LineDiff.NumberedLine]) -> CGFloat {
        let biggest = rows.reduce(1) { max($0, $1.old ?? 0, $1.new ?? 0) }
        return CGFloat(String(biggest).count) * 7 + 10
    }

    private func hunkGap(_ gutter: CGFloat) -> some View {
        Text("⋯")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Theme.secondaryText)
            .padding(.leading, gutter * 2 + 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 1)
    }
}

private struct DiffRow: View {
    let row: LineDiff.NumberedLine
    let gutter: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            number(row.old)
            number(row.new)
            Text(marker)
                .frame(width: 14)
                .foregroundStyle(Theme.secondaryText)
            Text(row.line.text)
                .foregroundStyle(row.line.kind == .context ? Theme.secondaryText : Theme.primaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11.5, design: .monospaced))
        .padding(.trailing, 10)
        .padding(.vertical, 0.5)
        .background(fill)
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(Theme.secondaryText.opacity(0.7))
            .frame(width: gutter, alignment: .trailing)
    }

    private var marker: String {
        switch row.line.kind {
        case .context: " "
        case .added: "+"
        case .removed: "-"
        }
    }

    private var fill: Color {
        switch row.line.kind {
        case .context: .clear
        case .added: Theme.diffAdded
        case .removed: Theme.diffRemoved
        }
    }
}

/// Under the Working row: the last lines a running command has printed, as it streams.
struct ToolLiveTail: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Theme.secondaryText)
            .lineLimit(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.planCardBackground))
            .padding(.leading, 34)
            .accessibilityIdentifier("chat-working-output")
    }
}
