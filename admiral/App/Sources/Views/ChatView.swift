import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AdmiralCore

/// The Chat rendering of a claude session: what you asked, what the agent said when it
/// stopped, and the moments it needs you. Thinking never appears, nor do a PTY tab's tool
/// calls (an ACP tab shows each as a `ToolCard`); while the agent works there is one
/// "Working…" row, whose tooltip names its current action.
///
/// It only renders the ledger (`SessionManager.chats`) and types into the same PTY the
/// Terminal view shows — it keeps no conversation state of its own, which is what keeps the
/// two views in step.
struct ChatView: View {
    @EnvironmentObject var model: AppModel
    let session: AgentSession

    @State private var position = ScrollPosition(edge: .bottom)
    @State private var isAtBottom = true

    /// Older items paged in above the live window as the reader scrolls up (`ChatHistory`).
    /// They stay while the tab is open; switching tabs frees them (the view is `.id`'d per
    /// session). Dropping them on reaching the bottom made the scroll jumpy.
    @State private var history: [ChatItem] = []
    @State private var historyExhausted = false
    @State private var loadingHistory = false
    /// The latest scroll geometry: where the reader is, and how tall the content is.
    @State private var viewportTop: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    /// Set just before a page is prepended: the reader's offset and the content height then.
    /// When the taller content lays out, the offset is pushed down by exactly the added height,
    /// so what they were reading stays put.
    @State private var pendingPrepend: (top: CGFloat, height: CGFloat)?

    private var chat: ChatTranscript { model.sessions.chats[session.id] ?? .empty }
    private var isWorking: Bool { session.status == .busy && !chat.isWaiting }

    /// The gap between consecutive tool cards (the list's own spacing is 18).
    private static let toolRunGap: CGFloat = 4

    /// The newest running tool call's streamed output, last 6 lines — nil when none is streaming.
    private var liveOutput: String? {
        guard !session.acpLiveOutput.isEmpty else { return nil }
        for item in chat.items.reversed() {
            guard case let .tool(_, tool, _) = item, tool.status == .running,
                  let output = session.acpLiveOutput[tool.id] else { continue }
            let tail = ChatTool.tail(output, lines: 6)
            return tail.isEmpty ? nil : tail
        }
        return nil
    }

    /// History first, then the live window — without an item both happen to hold.
    private var items: [ChatItem] {
        let live = Set(chat.items.map(\.id))
        return history.filter { !live.contains($0.id) } + chat.items
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                // Eager, not lazy: the prepend math needs exact heights (a lazy stack only
                // estimates rows it hasn't drawn), and paging keeps the list small.
                VStack(alignment: .leading, spacing: 18) {
                    historyHeader
                    if items.isEmpty && historyExhausted { emptyState }
                    let dayBreaks = ChatHistory.dayBreaks(items)
                    let toolFollowers = ChatHistory.toolRunFollowers(items, dayBreaks: dayBreaks)
                    ForEach(items) { item in
                        if dayBreaks.contains(item.id) { DayDivider(ts: item.ts) }
                        ChatItemView(item: item, session: session).equatable()
                            // A run of tool calls reads as one group: each after the first
                            // takes back most of the stack's spacing.
                            .padding(.top, toolFollowers.contains(item.id) ? Self.toolRunGap - 18 : 0)
                    }
                    if isWorking {
                        WorkingRow(session: session, since: chat.lastPromptTS, liveOutput: liveOutput)
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
                .padding(.horizontal, 28)
            }
            .scrollPosition($position)
            // `visibleRect` is in content coordinates. `contentOffset` is not: on macOS it
            // carries the toolbar's content inset, so "at the bottom" never quite held and the
            // jump button stayed up while parked at the bottom.
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.visibleRect.maxY >= geo.contentSize.height - 40
            } action: { _, atBottom in
                if isAtBottom != atBottom { isAtBottom = atBottom }
            }
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.visibleRect.minY
            } action: { _, top in
                viewportTop = top
                // Near the top of a chat the reader scrolled up through → the next older page.
                // (`!isAtBottom`: before the opening scroll-to-bottom lands, the offset is 0.)
                if top < 60, !isAtBottom, contentHeight > 0, pendingPrepend == nil { loadOlder() }
            }
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentSize.height
            } action: { _, height in
                contentHeight = height
                guard let pending = pendingPrepend, height != pending.height else { return }
                pendingPrepend = nil
                position.scrollTo(y: pending.top + (height - pending.height))
            }
            .onChange(of: chat.items.count) { followTail(); fillIfShort() }
            .onChange(of: session.transcriptPath) { fillIfShort() }
            .onChange(of: isWorking) { followTail() }
            .onAppear {
                position.scrollTo(edge: .bottom)
                fillIfShort()
            }
            .overlay(alignment: .bottom) { jumpToLatest }
            .environment(\.openURL, OpenURLAction { url in
                guard url.isFileURL else {
                    return TerminalLink.isWebURL(url) ? .systemAction : .discarded
                }
                model.openChatFile(url)
                return .handled
            })
            .accessibilityIdentifier("chat-content")

            if session.backend != .pty { AcpTabStrip(session: session) }
            ChatComposer(session: session, isWorking: session.status == .busy, onSend: jumpToBottom)
        }
        .paneBackground(Theme.contentBackground)
    }

    private func followTail() {
        guard isAtBottom else { return }
        withAnimation(.easeOut(duration: 0.15)) { position.scrollTo(edge: .bottom) }
    }

    /// Sending a message takes the reader to the bottom and keeps following, so their prompt,
    /// and the reply after it, land in view.
    private func jumpToBottom() {
        isAtBottom = true
        withAnimation(.easeOut(duration: 0.2)) { position.scrollTo(edge: .bottom) }
    }

    // MARK: - Paging

    /// A short live window (a conversation older than the ledger, or a fresh one) is topped
    /// up with the newest history, so the tab opens on its last few messages.
    private func fillIfShort() {
        guard history.isEmpty, !historyExhausted, chat.items.count < ChatHistory.pageSize else { return }
        loadOlder(opening: true)
    }

    /// The page just older than what is shown, prepended with the reader's place kept.
    private func loadOlder(opening: Bool = false) {
        guard !loadingHistory, !historyExhausted, let sid = session.claudeSessionID else { return }
        loadingHistory = true
        let cursor = (history.first ?? chat.items.first)?.ts
        let base = model.sessions.supportDir
        let transcript = session.transcriptPath
        let tools = session.backend.isACP
        Task.detached(priority: .userInitiated) {
            let page = ChatHistory.page(
                base: base, session: sid, transcriptPath: transcript, before: cursor, tools: tools)
            await MainActor.run {
                loadingHistory = false
                // No transcript yet (claude hasn't written it): not the end, just not ready.
                historyExhausted = !page.hasMore && transcript != nil
                guard !page.items.isEmpty else { return }
                if opening {
                    history = page.items + history
                    position.scrollTo(edge: .bottom)
                } else {
                    pendingPrepend = (viewportTop, contentHeight)
                    history = page.items + history
                }
            }
        }
    }

    @ViewBuilder private var historyHeader: some View {
        if loadingHistory {
            HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
        } else if historyExhausted, !items.isEmpty {
            Text("Beginning of conversation")
                .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nothing here yet.").font(.system(size: 14, weight: .medium))
            Text("Messages to and from this session show here.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(.top, 30)
    }

    @ViewBuilder private var jumpToLatest: some View {
        if !isAtBottom {
            Button {
                isAtBottom = true
                withAnimation(.easeOut(duration: 0.2)) { position.scrollTo(edge: .bottom) }
            } label: {
                Label("Jump to latest", systemImage: "arrow.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Rectangle().fill(Theme.accent).shadow(radius: 6, y: 2))
            }
            .buttonStyle(.plain)
            .padding(.bottom, 12)
        }
    }
}

// MARK: - Items

/// One chat row. Equatable on what it draws, so the app's 1s refresh (which touches the
/// session's status and activity fields) doesn't rebuild rows whose content is unchanged —
/// a rebuild clears any text the reader has selected, which made copying impossible.
private struct ChatItemView: View, Equatable {
    @EnvironmentObject var model: AppModel
    let item: ChatItem
    let session: AgentSession

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item && lhs.session.id == rhs.session.id
            && lhs.session.avatarColorHex == rhs.session.avatarColorHex
            && lhs.session.avatarSymbolName == rhs.session.avatarSymbolName
    }

    var body: some View {
        switch item {
        case let .prompt(_, text, source, ts):
            PromptBubble(text: text, source: source, ts: ts, cwd: session.cwd)
                .contextMenu { CopyButton(text: text) }
        case let .reply(_, text, ts):
            ReplyView(text: text, ts: ts, session: session)
                .contextMenu { CopyButton(text: text) }
        case let .ask(_, questions, _, open):
            if open {
                AskCard(questions: questions) { model.answerAsk(questions, answers: $0, for: session) }
            } else {
                AskSummary(questions: questions)
            }
        case let .needs(_, text, _, open):
            if open { NeedsCard(text: text, session: session) } else { EmptyView() }
        case let .notice(_, text, ts):
            NoticeLine(text: text, ts: ts)
                .contextMenu { CopyButton(text: text) }
        case let .tool(_, tool, _):
            ToolCard(tool: tool)
        }
    }
}

/// Right-click → Copy: the whole message, whether or not any of it is selected.
private struct CopyButton: View {
    let text: String

    var body: some View {
        Button("Copy Message") { ChatClipboard.copy(text) }
    }
}

/// The chat's clipboard writes, in one place so every copy path agrees.
enum ChatClipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// A table goes on the clipboard twice over: markdown as the plain text (a chat, an
    /// editor, a PR), tab-separated as tabular text (Numbers, Sheets, Excel take rows and
    /// columns from it). The pasting app picks the one it understands.
    static func copyTable(header: [String], rows: [[String]]) {
        let board = NSPasteboard.general
        board.clearContents()
        board.declareTypes([.string, .tabularText], owner: nil)
        board.setString(ChatMarkdown.markdown(header: header, rows: rows), forType: .string)
        board.setString(ChatMarkdown.tsv(header: header, rows: rows), forType: .tabularText)
    }
}

/// The copy control shared by messages and tables: an icon that turns into "✓ Copied" for a
/// moment after a click, so it's clear it worked without relying on colour. Its host decides
/// when it shows (on hover); once clicked it reports `copied` so the host keeps it visible
/// through the confirmation.
struct CopyControl: View {
    let label: String
    var help: String? = nil
    @Binding var copied: Bool
    let copy: () -> Void

    var body: some View {
        Button {
            copy()
            withAnimation(.easeOut(duration: 0.12)) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation(.easeOut(duration: 0.2)) { copied = false }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                if copied { Text("Copied").font(.system(size: 11, weight: .medium)) }
            }
            .foregroundStyle(copied ? Theme.checkGreen : Theme.secondaryText)
            .padding(.horizontal, 6)
            .frame(minWidth: 24, minHeight: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help ?? label)
        .accessibilityLabel(copied ? "Copied" : label)
    }
}

/// Shows its content on hover (and while a copy confirmation is up), fading rather than
/// appearing, and always present for VoiceOver. Hidden, it keeps its space — nothing shifts.
private struct HoverReveal: ViewModifier {
    let visible: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: visible)
            .accessibilityHidden(false)
    }
}

extension View {
    fileprivate func revealed(when visible: Bool) -> some View { modifier(HoverReveal(visible: visible)) }
}

/// Chat text with the file paths in it made clickable, the way claude's own output is in a
/// terminal. The line (if the path named one) rides in the URL fragment for `AppModel.open`.
enum ChatText {
    /// `mentions` (group window only): lowercased member handle → its color. Each `@handle`
    /// that `GroupMention` would route on is drawn in that member's color (`@all` in accent).
    static func attributed(_ text: String, cwd: String, mentions: [String: Color] = [:]) -> AttributedString {
        var attributed = AssistantText.styled(text)
        let plain = String(attributed.characters)
        if !mentions.isEmpty {
            for token in GroupMention.mentions(plain, names: Array(mentions.keys)) {
                let characters = attributed.characters
                guard let start = characters.index(characters.startIndex, offsetBy: token.offset,
                                                   limitedBy: characters.endIndex),
                      let end = characters.index(start, offsetBy: token.length,
                                                 limitedBy: characters.endIndex) else { continue }
                attributed[start..<end].foregroundColor = mentions[token.name.lowercased()] ?? Theme.accent
                attributed[start..<end].font = .system(size: 14, weight: .medium)
            }
        }
        for link in ChatLinks.detect(in: plain, cwd: cwd) {
            let characters = attributed.characters
            guard let start = characters.index(characters.startIndex, offsetBy: link.offset,
                                               limitedBy: characters.endIndex),
                  let end = characters.index(start, offsetBy: link.length,
                                             limitedBy: characters.endIndex) else { continue }
            var components = URLComponents(url: link.url, resolvingAgainstBaseURL: false)
            components?.fragment = link.line.map { "L\($0)" }
            guard let url = components?.url else { continue }
            attributed[start..<end].link = url
            attributed[start..<end].underlineStyle = .single
            attributed[start..<end].foregroundColor = Theme.accent
        }
        return attributed
    }
}

/// A chat message's body: its markdown blocks (`ChatMarkdown`) drawn as a reader expects —
/// tables as a grid, fenced code monospaced, headings bold, paragraphs as styled text with
/// file paths clickable. Each block stays selectable.
struct ChatMarkdownView: View {
    let text: String
    let cwd: String
    var fontSize: CGFloat = 14
    /// Group window: member handles to color (see `ChatText.attributed`).
    var mentions: [String: Color] = [:]

    var body: some View {
        let blocks = ChatMarkdown.blocks(text)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks.indices, id: \.self) { i in block(blocks[i]) }
        }
    }

    @ViewBuilder private func block(_ block: ChatBlock) -> some View {
        switch block {
        case let .paragraph(text):
            Text(ChatText.attributed(text, cwd: cwd, mentions: mentions))
                .font(.system(size: fontSize))
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case let .heading(level, text):
            Text(ChatText.attributed(text, cwd: cwd))
                .font(.system(size: level <= 1 ? fontSize + 3 : fontSize + 1, weight: .semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case let .code(_, code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: fontSize - 1.5, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding(10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.planCardBackground))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.bubbleBorder))
        case let .table(header, rows):
            ChatTableView(header: header, rows: rows, cwd: cwd, fontSize: fontSize)
        }
    }
}

/// A markdown table as a grid, with its own Copy (top-right, on hover) that puts the table
/// on the clipboard as markdown and as tab-separated rows for spreadsheets.
private struct ChatTableView: View {
    let header: [String]
    let rows: [[String]]
    let cwd: String
    let fontSize: CGFloat

    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 7) {
            GridRow {
                ForEach(header.indices, id: \.self) { c in cell(header[c]).fontWeight(.semibold) }
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(rows.indices, id: \.self) { r in
                GridRow {
                    ForEach(rows[r].indices, id: \.self) { c in cell(rows[r][c]) }
                }
                if r < rows.count - 1 { Divider().opacity(0.5).gridCellUnsizedAxes(.horizontal) }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.planCardBackground))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.bubbleBorder))
        // Floats over the table's corner on a material pill, so it reads over any cell.
        .overlay(alignment: .topTrailing) {
            CopyControl(label: "Copy table",
                        help: "Copy table — pastes as a table in editors and as rows and columns in a spreadsheet",
                        copied: $copied, copy: copy)
                .background(Rectangle().fill(.regularMaterial))
                .overlay(Rectangle().stroke(Theme.bubbleBorder))
                .padding(6)
                .revealed(when: hovering || copied)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { Button("Copy Table", action: copy) }
    }

    private func copy() { ChatClipboard.copyTable(header: header, rows: rows) }

    private func cell(_ text: String) -> Text {
        Text(ChatText.attributed(text, cwd: cwd)).font(.system(size: fontSize - 1))
    }
}

/// A harness notice (a background task ended): plain muted text, not a bubble — nobody in
/// the conversation said it.
private struct NoticeLine: View {
    let text: String
    let ts: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.secondaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text(ChatTime.short(ts)).font(.system(size: 11)).foregroundStyle(Theme.secondaryText.opacity(0.7))
                .help(ChatTime.full(ts))
            Spacer(minLength: 0)
        }
        .padding(.leading, 34)
    }
}

/// The human's message, right-aligned. Shared with the group window.
struct PromptBubble: View {
    let text: String
    let source: String?
    let ts: String
    let cwd: String
    var mentions: [String: Color] = [:]

    var body: some View {
        HStack {
            Spacer(minLength: 80)
            VStack(alignment: .trailing, spacing: 4) {
                ChatMarkdownView(text: text, cwd: cwd, mentions: mentions)
                    .foregroundStyle(Theme.primaryText)
                    .padding(.horizontal, 13).padding(.vertical, 9)
                    .background(UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 14,
                                                       bottomTrailingRadius: 4, topTrailingRadius: 14)
                        .fill(Theme.userPromptBackground))
                HStack(spacing: 4) {
                    CopyControl(label: "Copy message", copied: $copied) { ChatClipboard.copy(text) }
                        .revealed(when: hovering || copied)
                    Text(meta).font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                        .help(ChatTime.full(ts))
                }
                .frame(height: 18)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    @State private var hovering = false
    @State private var copied = false

    private var meta: String {
        let time = ChatTime.short(ts)
        guard let source else { return time }
        return "\(time) · sent by Admiral (\(source))"
    }
}

/// An agent's message: avatar, (in a group) the author's name, the time, then the text.
/// Shared with the group window, which passes the author's snapshotted look and name.
struct ReplyView: View {
    let text: String
    let ts: String
    let avatar: Avatar
    var name: String? = nil
    let cwd: String
    var mentions: [String: Color] = [:]

    init(text: String, ts: String, session: AgentSession) {
        self.init(text: text, ts: ts, avatar: Avatar(session: session, size: ChatMetrics.avatar), cwd: session.cwd)
    }

    init(text: String, ts: String, avatar: Avatar, name: String? = nil, cwd: String,
         mentions: [String: Color] = [:]) {
        self.text = text; self.ts = ts; self.avatar = avatar; self.name = name
        self.cwd = cwd; self.mentions = mentions
    }

    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            avatar
            VStack(alignment: .leading, spacing: 3) {
                // The copy control rides the timestamp line, so it costs no height.
                HStack(spacing: 4) {
                    if let name {
                        Text(name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.primaryText)
                            .lineLimit(1).padding(.trailing, 2)
                    }
                    Text(ChatTime.short(ts)).font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                        .help(ChatTime.full(ts))
                    CopyControl(label: "Copy message", copied: $copied) { ChatClipboard.copy(text) }
                        .revealed(when: hovering || copied)
                }
                .frame(height: 18)
                ChatMarkdownView(text: text, cwd: cwd, mentions: mentions)
                    .foregroundStyle(Theme.primaryText)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// The chat's shared measurements, so the group window can't drift from them.
enum ChatMetrics {
    /// The sidebar's own avatar (same rounded square, same gradient), at chat size.
    static let avatar: CGFloat = 24
}

private struct SessionAvatarDot: View {
    let session: AgentSession

    var body: some View { Avatar(session: session, size: ChatMetrics.avatar) }
}

/// The working capsule's own content: the pulse, a label, and the elapsed time.
struct WorkingCapsule<Label: View>: View {
    let elapsed: String?
    @ViewBuilder let label: Label

    var body: some View {
        HStack(spacing: 8) {
            PulseDot()
            label
            if let elapsed {
                Text(elapsed).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(Theme.secondaryText)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Rectangle().fill(Theme.chipBackground))
    }
}

private struct WorkingRow: View {
    @EnvironmentObject var model: AppModel
    let session: AgentSession
    let since: String?
    /// An ACP tab's running command's latest output lines, shown under the capsule.
    var liveOutput: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                SessionAvatarDot(session: session)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    WorkingCapsule(elapsed: elapsed(at: context.date)) {
                        Text("Working…").font(.system(size: 13)).foregroundStyle(Theme.secondaryText)
                    }
                }
                .help(currentAction)
                Spacer(minLength: 0)
            }
            .accessibilityIdentifier("chat-working")
            if let liveOutput { ToolLiveTail(text: liveOutput) }
        }
    }

    /// The last tool call in the transcript — the hover detail, never a message.
    private var currentAction: String {
        let turns = model.sessions.conversations[session.id]?.turns ?? []
        for turn in turns.reversed() {
            if case let .tool(_, name, params, _, _) = turn {
                return params.isEmpty ? name : "\(name) · \(params)"
            }
        }
        return "Working"
    }

    private func elapsed(at now: Date) -> String? {
        guard let since, let start = ChatTime.date(since) else { return nil }
        return GroupWorkingWords.elapsedLabel(Int(now.timeIntervalSince(start)))
    }
}

struct PulseDot: View {
    @State private var dim = false

    var body: some View {
        Circle().fill(Theme.busyAmber).frame(width: 8, height: 8)
            .opacity(dim ? 0.35 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

// MARK: - Needs you

/// Questions from the bridge's AskUserQuestion mirror. Pick, then Submit: the answers go in
/// as the next prompt, and that prompt closes the card. Shared with the group window, which
/// shows a member's question with this same card.
struct AskCard: View {
    let questions: [AskQuestion]
    /// The answers, one per question (multi-select joined with ", ").
    let onSubmit: ([String]) -> Void
    /// Left inset: the tab's card sits under the agent's reply text; the group's under its own
    /// name row, which already has the avatar column.
    var leading: CGFloat = 34

    @State private var picks: [Set<Int>] = []
    @State private var other: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardHeader(title: questions.count > 1 ? "\(questions.count) questions" : "Question")
            VStack(alignment: .leading, spacing: 16) {
                ForEach(questions.indices, id: \.self) { q in question(q) }
                HStack {
                    Spacer()
                    Button("Submit answers") { submit() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                        .disabled(!complete)
                        .keyboardShortcut(.return, modifiers: .command)
                        .accessibilityIdentifier("ask-submit")
                }
            }
            .padding(12)
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.planCardBackground))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.bubbleBorder))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.leading, leading)
        .onAppear {
            if picks.count != questions.count {
                picks = Array(repeating: [], count: questions.count)
                other = Array(repeating: "", count: questions.count)
            }
        }
        .accessibilityIdentifier("ask-card")
    }

    @ViewBuilder private func question(_ q: Int) -> some View {
        let question = questions[q]
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if !question.header.isEmpty {
                    Text(question.header.uppercased())
                        .font(.system(size: 10, weight: .semibold)).tracking(0.4)
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Rectangle().fill(Theme.chipBackground))
                }
                if question.multiSelect {
                    Text("Pick any").font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                }
            }
            Text(question.question).font(.system(size: 14, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            ForEach(question.options.indices, id: \.self) { o in
                option(q, o, question.options[o], multi: question.multiSelect)
            }
            TextField("Other — type your own answer", text: binding(q))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
        }
    }

    private func option(_ q: Int, _ o: Int, _ option: AskOption, multi: Bool) -> some View {
        let selected = q < picks.count && picks[q].contains(o)
        return Button { toggle(q, o, multi: multi) } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: multi ? (selected ? "checkmark.square.fill" : "square")
                                        : (selected ? "largecircle.fill.circle" : "circle"))
                    .font(.system(size: 14))
                    .foregroundStyle(selected ? Theme.accent : Theme.secondaryText)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.primaryText)
                    if let description = option.description, !description.isEmpty {
                        Text(description).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let preview = option.preview, !preview.isEmpty {
                        Text(preview).font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Theme.primaryText)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.contentBackground))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Theme.accent.opacity(0.1) : Theme.bubbleBackground))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Theme.accent : Theme.bubbleBorder))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func binding(_ q: Int) -> Binding<String> {
        Binding(get: { q < other.count ? other[q] : "" },
                set: { value in
                    guard q < other.count else { return }
                    other[q] = value
                    if !value.isEmpty, !questions[q].multiSelect { picks[q].removeAll() }
                })
    }

    private func toggle(_ q: Int, _ o: Int, multi: Bool) {
        guard q < picks.count else { return }
        if multi {
            if picks[q].contains(o) { picks[q].remove(o) } else { picks[q].insert(o) }
        } else {
            picks[q] = [o]
            other[q] = ""
        }
    }

    private func answer(_ q: Int) -> String {
        guard q < picks.count else { return "" }
        var labels = picks[q].sorted().map { questions[q].options[$0].label }
        let typed = other[q].trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { labels.append(typed) }
        return labels.joined(separator: ", ")
    }

    private var complete: Bool { questions.indices.allSatisfy { !answer($0).isEmpty } }

    private func submit() {
        onSubmit(questions.indices.map(answer))
    }
}

struct AskSummary: View {
    let questions: [AskQuestion]
    var leading: CGFloat = 34

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.checkGreen)
            Text("Asked: " + questions.map { $0.header.isEmpty ? $0.question : $0.header }.joined(separator: " · "))
                .foregroundStyle(Theme.secondaryText)
        }
        .font(.system(size: 11.5))
        .padding(.leading, leading)
    }
}

private struct NeedsCard: View {
    @EnvironmentObject var model: AppModel
    let text: String
    let session: AgentSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardHeader(title: "Needs you · permission")
            VStack(alignment: .leading, spacing: 10) {
                Text(text).font(.system(size: 13.5)).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Allow") { model.allowPermission(session) }
                        .buttonStyle(.borderedProminent).tint(Theme.accent)
                    Button("Deny") { model.interrupt(session) }
                    // An ACP tab has no terminal to open.
                    if session.backend == .pty {
                        Button("Open in terminal") { model.setViewMode(.terminal, for: session) }
                            .buttonStyle(.link)
                    }
                }
            }
            .padding(12)
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.planCardBackground))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.bubbleBorder))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.leading, 34)
        .accessibilityIdentifier("needs-card")
    }
}

private struct CardHeader: View {
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Theme.attention).frame(width: 6, height: 6)
            Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.attention)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Theme.planCardHeader)
    }
}

// MARK: - Composer

/// Types into the session exactly as the terminal prompt would take it: Enter sends,
/// Shift+Enter is a newline, files dropped or attached ride along as escaped paths, and
/// while the agent works the send button becomes Stop (Esc).
struct ChatComposer: View {
    @EnvironmentObject var model: AppModel
    let session: AgentSession
    let isWorking: Bool
    /// Called after a send — the chat scrolls to the bottom to show it.
    var onSend: () -> Void = {}

    @State private var text = ""
    @State private var attachments: [String] = []
    /// An ACP option the agent refused, until the next pick.
    @State private var optionError: String?
    /// The highlighted row of whichever menu is open (`/` or `@` — never both).
    @State private var menuSelection = 0
    /// The text Esc closed the open menu on; it stays closed until the text changes.
    @State private var menuDismissedText: String?
    /// The agent's files for the open `@` query, fetched once per open.
    @State private var fileList: AcpFileListState = .idle
    /// The tab the in-flight listing was asked for: a result for any other tab is dropped.
    @State private var fileListTab: UUID?
    /// Every file any listing on this tab returned: what a sent `@path` is checked against.
    @State private var knownFiles: Set<String> = []
    @FocusState private var focused: Bool

    private var hasContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    private var slashCandidates: [AcpCommandInfo] {
        guard session.backend != .pty, text != menuDismissedText,
              let partial = SlashCommandPicker.query(in: text) else { return [] }
        return SlashCommandPicker.candidates(partial, commands: session.acpCommands)
    }

    private var slashOpen: Bool { !slashCandidates.isEmpty }

    /// The `@` query, on an ACP tab, when the `/` menu's text shape is not the one typed.
    private var fileQuery: FileMentionPicker.Query? {
        guard session.backend != .pty, SlashCommandPicker.query(in: text) == nil else { return nil }
        return FileMentionPicker.query(in: text)
    }

    /// The `@` menu, when it shows: a notice while loading / with no list, else the matches
    /// (none = closed).
    private var fileMenu: AcpFileMenuContent? {
        guard text != menuDismissedText, let query = fileQuery else { return nil }
        switch fileList {
        case .idle, .loading: return .loading
        case .unavailable: return .unavailable
        case let .loaded(files):
            let matches = FileMentionPicker.candidates(query.partial, files: files)
            return matches.isEmpty ? nil : .files(matches)
        }
    }

    /// The files the keys move through and accept (a notice row takes no keys).
    private var fileCandidates: [String] {
        if case let .files(files) = fileMenu { files } else { [] }
    }

    private var menuRowCount: Int { slashOpen ? slashCandidates.count : fileCandidates.count }

    /// "Loading files…" is up: Return / Tab mean "pick", so they wait instead of sending a
    /// half-typed `@` (the permanent "unavailable" notice still lets Return send).
    private var fileMenuLoading: Bool { fileMenu == .loading }

    /// The hint of the command whose "/name " is the whole text, shown after it.
    private var slashHint: String? {
        guard session.backend != .pty else { return nil }
        return session.acpCommands.first { $0.hint != nil && text == SlashCommandPicker.insert($0) }?.hint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let optionError { AcpOptionErrorCaption(text: optionError) }
            if !attachments.isEmpty { chips }
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Message \(session.displayTitle) — drop files, / commands, @ files")
                        .font(.system(size: 14)).foregroundStyle(Theme.secondaryText)
                        .padding(.top, 1).padding(.leading, 5)
                        .allowsHitTesting(false)
                } else if let slashHint {
                    (Text(text).foregroundColor(.clear) + Text(slashHint).foregroundColor(Theme.secondaryText))
                        .font(.system(size: 14))
                        .padding(.top, 1).padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 22, maxHeight: 160)
                    .fixedSize(horizontal: false, vertical: true)
                    .focused($focused)
                    .onKeyPress(.return, phases: .down) { press in
                        if menuRowCount > 0 { acceptMenu(); return .handled }
                        if fileMenuLoading { return .handled }
                        if press.modifiers.contains(.shift) || press.modifiers.contains(.option) { return .ignored }
                        send()
                        return .handled
                    }
                    .onKeyPress(.tab) {
                        if menuRowCount > 0 { acceptMenu(); return .handled }
                        return fileMenuLoading ? .handled : .ignored
                    }
                    .onKeyPress(.upArrow) { moveMenu(-1) }
                    .onKeyPress(.downArrow) { moveMenu(1) }
                    .onKeyPress(.escape) {
                        if slashOpen || fileMenu != nil { menuDismissedText = text; return .handled }
                        guard text.isEmpty, isWorking else { return .ignored }
                        model.interrupt(session)
                        return .handled
                    }
                    .accessibilityIdentifier("chat-input")
            }
            HStack(spacing: 6) {
                Button(action: attach) { Image(systemName: "plus") }
                    .buttonStyle(.plain).foregroundStyle(Theme.secondaryText)
                    .help("Attach files")
                if session.backend != .pty {
                    AcpOptionChips(session: session) { optionError = $0 }
                }
                ComposerHint(isWorking: isWorking)
                Spacer()
                ComposerSendButton(stop: isWorking && !hasContent, hasContent: hasContent, isWorking: isWorking,
                                   onStop: { model.interrupt(session) }, onSend: send)
            }
        }
        .composerBox(focused: focused || slashOpen || fileMenu != nil)
        // Anchored above the box: a zero-height strip on its top edge, the list hanging up from it.
        .overlay(alignment: .top) {
            if slashOpen {
                Color.clear.frame(maxWidth: .infinity).frame(height: 0)
                    .overlay(alignment: .bottom) {
                        AcpSlashMenu(candidates: slashCandidates,
                                     selection: min(menuSelection, slashCandidates.count - 1)) { acceptMenu($0) }
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 6)
                    }
            } else if let fileMenu {
                Color.clear.frame(maxWidth: .infinity).frame(height: 0)
                    .overlay(alignment: .bottom) {
                        AcpFileMenu(content: fileMenu,
                                    selection: min(menuSelection, max(fileCandidates.count - 1, 0))) { acceptMenu($0) }
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 6)
                    }
            }
        }
        .composerColumn()
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL).map(\.path)
            attachments.append(contentsOf: files)
            return !files.isEmpty
        }
        .onAppear { focused = true }
        .onChange(of: text) { menuSelection = 0 }
        .onChange(of: fileQuery != nil) { _, open in open ? loadFiles() : (fileList = .idle) }
        .onChange(of: session.id) {
            text = ""; attachments = []; optionError = nil; menuDismissedText = nil; focused = true
            fileList = .idle; fileListTab = nil; knownFiles = []
        }
    }

    private func moveMenu(_ delta: Int) -> KeyPress.Result {
        let count = menuRowCount
        guard count > 0 else { return .ignored }
        menuSelection = GroupMentionPicker.move(min(menuSelection, count - 1), by: delta, count: count)
        return .handled
    }

    /// Return / Tab / a click on the open menu's row.
    private func acceptMenu(_ index: Int? = nil) {
        let count = menuRowCount
        guard count > 0 else { return }
        let i = min(index ?? menuSelection, count - 1)
        if slashOpen {
            text = SlashCommandPicker.insert(slashCandidates[i])
        } else if let query = fileQuery {
            text = FileMentionPicker.insert(fileCandidates[i], into: text, at: query)
        }
    }

    /// The `@` menu opened: list the agent's files (the manager caches them briefly), keeping
    /// every path seen so a sent `@path` is recognised.
    private func loadFiles() {
        fileList = .loading
        let tab = session
        fileListTab = tab.id
        Task {
            let files = await model.acpFiles(tab)
            // Closed meanwhile, or the composer moved to another tab (whose own load may be running).
            guard fileList == .loading, fileListTab == tab.id else { return }
            if let files {
                fileList = .loaded(files)
                knownFiles.formUnion(files)
            } else {
                fileList = .unavailable
            }
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments, id: \.self) { path in
                    HStack(spacing: 4) {
                        Text((path as NSString).abbreviatingWithTildeInPath)
                            .font(.system(size: 11.5, design: .monospaced)).lineLimit(1)
                        Button { attachments.removeAll { $0 == path } } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Rectangle().fill(Theme.chipBackground))
                }
            }
        }
    }

    private func send() {
        guard hasContent else { return }
        let mentions = session.backend == .pty ? [] : FileMentionPicker.mentions(in: text, files: knownFiles)
        model.sendChat(text, attachments: attachments, mentions: mentions, to: session)
        text = ""
        attachments = []
        onSend()
    }

    private func attach() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.directoryURL = URL(fileURLWithPath: session.cwd)
        if panel.runModal() == .OK { attachments.append(contentsOf: panel.urls.map(\.path)) }
    }
}

/// The composer's box: padding, radius, the accent border while focused, the reading width.
/// Shared by the tab and group composers so the two can't drift.
extension View {
    func composerChrome(focused: Bool) -> some View {
        composerBox(focused: focused).composerColumn()
    }

    /// The box itself.
    func composerBox(focused: Bool) -> some View {
        padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.bubbleBackground))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(focused ? Theme.accent : Theme.bubbleBorder))
    }

    /// Where the box sits: the timeline's reading width and margins.
    func composerColumn() -> some View {
        frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28).padding(.top, 6).padding(.bottom, 10)
    }
}

struct ComposerHint: View {
    let isWorking: Bool

    var body: some View {
        Text(isWorking ? "↵ queue · ⇧↵ newline · esc interrupt" : "↵ send · ⇧↵ newline")
            .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
    }
}

/// Send, or Stop while the agent works and nothing is typed.
struct ComposerSendButton: View {
    let stop: Bool
    let hasContent: Bool
    let isWorking: Bool
    let onStop: () -> Void
    let onSend: () -> Void

    var body: some View {
        if stop {
            Button(action: onStop) {
                RoundedRectangle(cornerRadius: 2).fill(Theme.contentBackground).frame(width: 9, height: 9)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Theme.primaryText))
            }
            .buttonStyle(.plain)
            .help("Stop (esc)")
            .accessibilityIdentifier("chat-stop")
        } else {
            Button(action: onSend) {
                Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(hasContent ? Theme.accent : Theme.pendingGray))
            }
            .buttonStyle(.plain)
            .disabled(!hasContent)
            .help(isWorking ? "Queue message" : "Send")
            .accessibilityIdentifier("chat-send")
        }
    }
}

// MARK: - Time

/// Chat timestamps. One parser for both sources — the ledger writes whole seconds, the
/// transcript milliseconds; a whole-seconds-only parser left every transcript message blank.
/// Messages show their time; the day lives on the divider above them (`DayDivider`), and the
/// full date and time is the time's hover tooltip.
enum ChatTime {
    static func date(_ iso: String) -> Date? { ChatHistory.date(iso) }

    static func short(_ iso: String) -> String { ChatHistory.timeLabel(iso) }

    static func full(_ iso: String) -> String { ChatHistory.fullLabel(iso) }
}

/// "Today" / "Yesterday" / "Monday, September 21" — above the first message of each day, so a
/// conversation that spans days says so wherever the reader is.
struct DayDivider: View {
    let ts: String

    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Theme.bubbleBorder).frame(height: 1)
            Text(ChatHistory.dayLabel(ts))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize()
            Rectangle().fill(Theme.bubbleBorder).frame(height: 1)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
