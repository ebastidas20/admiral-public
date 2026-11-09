import SwiftUI
import AdmiralCore

/// Shared transcript layout decisions, used by both the live (virtualized) view and
/// the offscreen snapshot column so they render identically.
enum TranscriptLayout {
    /// Task*/TodoWrite tool calls are represented by the plan card, not as tool rows.
    static let planTools: Set<String> = ["TaskCreate", "TaskUpdate", "TodoWrite"]

    static func visibleTurns(_ turns: [Turn]) -> [Turn] {
        turns.filter { turn in
            if case let .tool(_, name, _, _, _) = turn { return !planTools.contains(name) }
            return true
        }
    }
}

/// The Warp-style chat rendering of a session transcript.
///
/// - Virtualized: `LazyVStack` only materializes the rows near the viewport and frees
///   the rest, so a multi-thousand-line transcript doesn't blow memory (the data is
///   also tail-capped upstream in `TranscriptStore`).
/// - Follow-tail: stays pinned to the bottom as new turns stream in, but stops the
///   moment you scroll up to read history. A "jump to bottom" button resumes tailing.
struct TranscriptView: View {
    let conversation: Conversation

    @State private var position = ScrollPosition(edge: .bottom)
    @State private var isAtBottom = true

    private var turns: [Turn] { TranscriptLayout.visibleTurns(conversation.turns) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if turns.isEmpty && conversation.plan == nil { waitingState }
                ForEach(turns) { TurnView(turn: $0) }
                if let plan = conversation.plan {
                    PlanCard(plan: plan, title: conversation.title)
                }
            }
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)          // center the reading column
            .padding(.vertical, 22)
            .padding(.horizontal, 28)
        }
        .scrollPosition($position)
        // Track whether we're parked at the bottom (within 40pt) so we only auto-follow
        // when the user hasn't scrolled up to read history.
        .onScrollGeometryChange(for: Bool.self) { geo in
            geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 40
        } action: { _, atBottom in
            if isAtBottom != atBottom { isAtBottom = atBottom }
        }
        // New turns arrived: follow the tail only if we were already at the bottom.
        .onChange(of: conversation.turns.count) {
            guard isAtBottom else { return }
            withAnimation(.easeOut(duration: 0.15)) { position.scrollTo(edge: .bottom) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.contentBackground)
        .overlay(alignment: .bottom) { jumpToBottomButton }
    }

    private var waitingState: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Waiting for the session transcript… (switch to Terminal to watch it boot)")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(.top, 40)
    }

    @ViewBuilder private var jumpToBottomButton: some View {
        if !isAtBottom {
            Button {
                isAtBottom = true
                withAnimation(.easeOut(duration: 0.2)) { position.scrollTo(edge: .bottom) }
            } label: {
                Label("Jump to latest", systemImage: "arrow.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Rectangle().fill(Theme.accent).shadow(radius: 6, y: 2))
            }
            .buttonStyle(.plain)
            .padding(.bottom, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityIdentifier("jump-to-bottom")
        }
    }
}

/// The centered column of turns + plan card, eager (non-lazy) so it renders fully when
/// drawn offscreen by `ImageRenderer` for the snapshot/validation gate.
struct TranscriptContent: View {
    let conversation: Conversation

    private var visibleTurns: [Turn] { TranscriptLayout.visibleTurns(conversation.turns) }

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 16) {
                ForEach(visibleTurns) { TurnView(turn: $0) }
                if let plan = conversation.plan {
                    PlanCard(plan: plan, title: conversation.title)
                }
            }
            .frame(maxWidth: 860, alignment: .leading)
            Spacer(minLength: 0)
        }
    }
}

struct TurnView: View {
    let turn: Turn

    var body: some View {
        switch turn {
        case let .user(_, text):
            UserPrompt(text: text)
        case let .assistant(_, markdown, _):
            AssistantText(markdown: markdown)
        case let .thinking(_, text):
            ThinkingView(text: text)
        case let .tool(_, name, params, result, state):
            ToolRow(name: name, params: params, result: result, state: state)
        }
    }
}

/// A human prompt, rendered as the command the user issued — a Warp-style accent
/// chevron + the text in a faintly tinted card with a left accent rule. No avatar:
/// in a transcript the user's own lines don't need a face, and a guessed initial is
/// worse than none.
struct UserPrompt: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("❯")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.accent)
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(Theme.primaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.userPromptBackground))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Theme.accent)
                .frame(width: 3)
                .padding(.vertical, 6)
        }
    }
}

struct AssistantText: View {
    let markdown: String

    var body: some View {
        HStack {
            Text(Self.styled(markdown))
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(Theme.primaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(3)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
    }

    /// Render inline markdown, styling inline `code` spans as chips.
    static func styled(_ source: String) -> AttributedString {
        var attr = (try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(source)
        for run in attr.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attr[run.range].backgroundColor = Theme.codeChipBackground
            attr[run.range].foregroundColor = Theme.codeChipText
            attr[run.range].font = .system(size: 13.5, weight: .medium, design: .monospaced)
        }
        return attr
    }
}

struct ThinkingView: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "brain")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .italic()
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(4)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
    }
}

struct ToolRow: View {
    let name: String
    let params: String
    let result: String?
    let state: ToolState

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(color).font(.system(size: 12))
            Text(name).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.primaryText)
            if !params.isEmpty {
                Text(params)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.chipBackground))
    }

    private var icon: String {
        switch state {
        case .success: return "checkmark.circle.fill"
        case .error: return "xmark.octagon.fill"
        case .running: return "circle.dotted"
        }
    }
    private var color: Color {
        switch state {
        case .success: return Theme.checkGreen
        case .error: return .red
        case .running: return Theme.inProgressBlue
        }
    }
}
