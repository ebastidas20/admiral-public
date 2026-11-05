import Foundation

/// What the Chat view shows, assembled from its two sources, plus older pages on demand.
///
/// **The transcript** is the source for the conversation itself: every prompt the user
/// typed, every message the agent sent (mid-turn narration as well as the end-of-turn
/// answer), and the harness's own notices (hook feedback, API errors, slash commands and
/// their output, interrupts, compactions). **The chat ledger** adds only what the transcript
/// can't say: questions put through the AskUserQuestion mirror, permission prompts, and which
/// prompts Admiral typed rather than the user. Its Stop replies are not shown — the transcript
/// holds the same messages, and more.
///
/// **Tool calls** show only when asked for (`tools: true`, an ACP tab's Chat): each `tool_use`
/// opens a `.tool` event, `.running`, and its `tool_result` completes it in place. The PTY Chat
/// never asks, so it never shows them.
///
/// **A clear** (an ACP tab's `/clear`, marked by the mirror with `clearedField`) ends the history:
/// nothing older than the last one is shown, from either source, and no older page loads.
public enum ChatHistory {
    public static let pageSize = 30
    /// The transcript field that marks a user line as the clear marker, and what Chat shows for it.
    public static let clearedField = "admiralCleared"
    public static let clearedNotice = "Conversation cleared"
    /// How much of the transcript the live window parses each refresh.
    public static let liveTailLines = 800

    public struct Page: Equatable, Sendable {
        public var items: [ChatItem]
        /// There is still older history before `items`.
        public var hasMore: Bool
    }

    /// The newest `limit` items — the live window the app refreshes every second.
    public static func live(base: URL, session: String, transcriptPath: String?,
                            limit: Int = pageSize, tools: Bool = false) -> ChatTranscript {
        let transcript = transcriptPath.map { transcriptEvents(path: $0, tail: liveTailLines, tools: tools) } ?? []
        let events = timeline(sinceClear: transcript, ledger: ChatLedger.read(base: base, session: session))
        return ChatTranscript(items: Array(ChatFolder.fold(events).items.suffix(limit)))
    }

    /// The `limit` items immediately older than `cursor` (all the newest when nil).
    ///
    /// Reads both sources in full, off the main thread, and keeps only the page: paging costs
    /// a scan, never resident memory.
    public static func page(base: URL, session: String, transcriptPath: String?,
                            before cursor: String?, limit: Int = pageSize, tools: Bool = false) -> Page {
        let transcript = transcriptPath.map { transcriptEvents(path: $0, tail: nil, tools: tools) } ?? []
        let events = timeline(sinceClear: transcript,
                              ledger: ChatLedger.read(base: base, session: session, tail: nil))
        let all = ChatFolder.fold(events).items
        let cutoff = cursor.flatMap(date)
        let older = cutoff.map { cut in all.filter { (date($0.ts) ?? .distantPast) < cut } } ?? all
        return Page(items: Array(older.suffix(limit)), hasMore: older.count > limit)
    }

    /// `timeline` of what follows the transcript's last clear marker (itself kept, as the notice):
    /// older transcript events and ledger events from before it are dropped.
    static func timeline(sinceClear transcript: [ChatEvent], ledger: [ChatEvent]) -> [ChatEvent] {
        guard let i = transcript.lastIndex(where: { $0.kind == .notice && $0.cleared }),
              let cut = date(transcript[i].ts) else { return timeline(transcript: transcript, ledger: ledger) }
        return timeline(transcript: Array(transcript[i...]),
                        ledger: ledger.filter { (date($0.ts) ?? .distantPast) >= cut })
    }

    /// Merge the two sources into one time-ordered stream (see the type's comment for who
    /// supplies what).
    public static func timeline(transcript: [ChatEvent], ledger: [ChatEvent]) -> [ChatEvent] {
        var events = transcript
        // Attribute the prompts Admiral typed: match each tagged ledger prompt to the first
        // untagged transcript prompt with the same text.
        for tagged in ledger where tagged.kind == .prompt && tagged.source != nil {
            let key = ChatLedger.normalized(tagged.text ?? "")
            if let i = events.firstIndex(where: {
                $0.kind == .prompt && $0.source == nil && ChatLedger.normalized($0.text ?? "") == key
            }) {
                events[i].source = tagged.source
            }
        }
        events += ledger.filter { [.ask, .needs, .resolved].contains($0.kind) }
        return events.enumerated()
            .sorted { lhs, rhs in
                let l = date(lhs.element.ts) ?? .distantPast, r = date(rhs.element.ts) ?? .distantPast
                return l == r ? lhs.offset < rhs.offset : l < r
            }
            .map(\.element)
    }

    // MARK: - Reading a transcript

    /// A transcript file (its last `tail` lines, or all of it) as chat events.
    public static func transcriptEvents(path: String, tail: Int?, tools: Bool = false) -> [ChatEvent] {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        let start = tail.map { max(0, lines.count - $0) } ?? 0
        return transcriptEvents(lines: lines[start...], firstLine: start + 1, tools: tools)
    }

    /// Transcript lines as chat events, each `id`'d by its (negated) line number so it keeps
    /// its identity however much of the file was read.
    public static func transcriptEvents<Lines: Collection>(lines: Lines, firstLine: Int,
                                                           tools: Bool = false) -> [ChatEvent]
    where Lines.Element: StringProtocol {
        var events: [ChatEvent] = []
        /// Each open tool call's event, by its tool_use id, for its result to complete.
        var openTools: [String: Int] = [:]
        for (offset, line) in lines.enumerated() {
            guard line.contains(#""type":"user""#) || line.contains(#""type":"assistant""#),
                  let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  obj["isSidechain"] as? Bool != true,
                  let ts = obj["timestamp"] as? String,
                  let message = obj["message"] as? [String: Any] else { continue }
            let id = -(firstLine + offset)
            if let event = event(from: obj, message: message, ts: ts, id: id) { events.append(event) }
            guard tools, let blocks = message["content"] as? [[String: Any]] else { continue }
            for block in blocks {
                switch block["type"] as? String {
                case "tool_use":
                    // The tool_use LINE's id: unique only because the ACP mirror writes one
                    // tool_use per line and no text with it. A claude transcript can do both, so
                    // a caller passing `tools: true` for one would need ids of its own.
                    guard let tool = openedTool(block) else { continue }
                    openTools[tool.id] = events.count
                    events.append(ChatEvent(ts: ts, kind: .tool, id: id, tool: tool))
                case "tool_result":
                    guard let callID = block["tool_use_id"] as? String,
                          let index = openTools.removeValue(forKey: callID) else { continue }
                    events[index].tool?.status = block["is_error"] as? Bool == true ? .failed : .completed
                    events[index].tool?.detail = toolDetail(result: block, toolUseResult: obj["toolUseResult"])
                default:
                    continue
                }
            }
        }
        return events
    }

    // MARK: - Tool calls

    /// A tool_use block as a running call; nil for `TodoWrite`, which is the plan, never a card.
    private static func openedTool(_ block: [String: Any]) -> ChatTool? {
        guard let callID = block["id"] as? String, let name = block["name"] as? String, name != "TodoWrite"
        else { return nil }
        let input = (block["input"]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }
            .flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        let params = ToolFormatter.params(name: name, input: input)
        return ChatTool(id: callID, name: name, title: params.isEmpty ? name : params)
    }

    /// What a finished call shows: its edit when the result names one (`toolUseResult`'s
    /// `filePath` + `newString`), else its output — `toolUseResult.stdout`, else the result's
    /// text — else nothing.
    static func toolDetail(result: [String: Any], toolUseResult: Any?) -> ChatTool.Detail {
        let structured = toolUseResult as? [String: Any]
        if let path = structured?["filePath"] as? String, let new = structured?["newString"] as? String {
            let old = structured?["oldString"] as? String ?? ""
            let created = structured?["type"] as? String == "create"
            return .diff(path: path, hunks: LineDiff.hunks(old: old, new: new), created: created)
        }
        let text = (structured?["stdout"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? unfenced(resultText(result["content"]))
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .none : .output(text)
    }

    /// A tool_result's content: a string, or its text blocks joined.
    private static func resultText(_ content: Any?) -> String {
        if let string = content as? String { return string }
        let blocks = content as? [[String: Any]] ?? []
        return blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .joined(separator: "\n")
    }

    /// claude-agent-acp wraps a command's output in one ```console block; show what is inside.
    static func unfenced(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```console\n"), trimmed.hasSuffix("\n```") || trimmed == "```console\n```"
        else { return text }
        let inner = trimmed.dropFirst("```console\n".count).dropLast("```".count)
        let body = inner.hasSuffix("\n") ? String(inner.dropLast()) : String(inner)
        return body.contains("\n```") ? text : body
    }

    private static func event(from obj: [String: Any], message: [String: Any], ts: String, id: Int) -> ChatEvent? {
        func notice(_ text: String) -> ChatEvent { ChatEvent(ts: ts, kind: .notice, text: text, id: id) }

        if obj["type"] as? String == "assistant" {
            guard let blocks = message["content"] as? [[String: Any]] else { return nil }
            let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            // A failed request is the harness speaking, not the agent.
            if obj["isApiErrorMessage"] as? Bool == true { return notice(text) }
            return ChatEvent(ts: ts, kind: .reply, text: text, id: id)
        }

        // user
        if obj["isCompactSummary"] as? Bool == true { return notice("Conversation compacted") }
        if obj[clearedField] as? Bool == true {
            var event = notice(clearedNotice)
            event.cleared = true
            return event
        }
        guard let text = userText(message["content"]) else { return nil }
        if obj["isMeta"] as? Bool == true {
            // Meta lines are the harness talking to the model. Hook feedback is the one worth
            // seeing: it is why a turn went on after the agent tried to stop.
            return hookFeedback(text).map(notice)
        }
        if text.hasPrefix("<command-name>") { return slashCommand(text).map(notice) }
        if text.hasPrefix("<local-command-stdout>") || text.hasPrefix("<local-command-stderr>") {
            return stripTags(text).map(notice)
        }
        if text.hasPrefix("[Request interrupted") { return notice("Interrupted") }
        if ignoredPrefixes.contains(where: { text.hasPrefix($0) }) { return nil }
        return ChatEvent(ts: ts, kind: .prompt, text: text, id: id)
    }

    /// A user line's text, or nil for tool results and empty lines.
    static func userText(_ content: Any?) -> String? {
        let text: String
        if let string = content as? String {
            text = string
        } else if let blocks = content as? [[String: Any]] {
            guard !blocks.contains(where: { $0["type"] as? String == "tool_result" }) else { return nil }
            text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined(separator: "\n")
        } else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static let ignoredPrefixes = ["<command-message>", "<system-reminder>", "<local-command-caveat>", "Caveat:"]

    /// "Stop hook feedback:\n…" → "Stop hook: …". Nil for any other meta line.
    static func hookFeedback(_ text: String) -> String? {
        guard let range = text.range(of: #"^\w+ hook feedback:\s*"#, options: .regularExpression) else { return nil }
        let event = text[..<range.lowerBound].isEmpty
            ? String(text[range].split(separator: " ").first ?? "Hook")
            : String(text[..<range.lowerBound])
        let body = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : "\(event) hook: \(body)"
    }

    /// `<command-name>/model</command-name>…<command-args>opus</command-args>` → "/model opus".
    static func slashCommand(_ text: String) -> String? {
        guard let name = TaskNotification.tag("command-name", in: text) else { return nil }
        let args = TaskNotification.tag("command-args", in: text) ?? ""
        return args.isEmpty ? name : "\(name) \(args)"
    }

    /// The text inside a harness tag like `<local-command-stdout>`, nil when empty.
    static func stripTags(_ text: String) -> String? {
        let stripped = text.replacingOccurrences(of: #"</?[a-z-]+>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? nil : stripped
    }

    // MARK: - Time

    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let whole = ISO8601DateFormatter()

    /// The ledger writes whole seconds, the transcript milliseconds; both parse.
    public static func date(_ iso: String) -> Date? {
        fractional.date(from: iso) ?? whole.date(from: iso)
    }

    // MARK: - When things happened

    private static func format(_ when: Date, _ template: String, calendar: Calendar, locale: Locale) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = calendar.timeZone
        f.setLocalizedDateFormatFromTemplate(template)
        return f.string(from: when)
    }

    /// A message's time of day ("2:05 PM") — the day itself is on the divider above it.
    public static func timeLabel(_ iso: String, calendar: Calendar = .current, locale: Locale = .current) -> String {
        date(iso).map { format($0, "jmm", calendar: calendar, locale: locale) } ?? ""
    }

    /// The full date and time, for a message's hover tooltip.
    public static func fullLabel(_ iso: String, calendar: Calendar = .current, locale: Locale = .current) -> String {
        date(iso).map { format($0, "EEEEyMMMMdjmm", calendar: calendar, locale: locale) } ?? ""
    }

    /// A day divider's title: "Today", "Yesterday", else the weekday and date — with the year
    /// once it isn't this one.
    public static func dayLabel(_ iso: String, now: Date = Date(), calendar: Calendar = .current,
                                locale: Locale = .current) -> String {
        guard let when = date(iso) else { return "" }
        if calendar.isDate(when, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(when, inSameDayAs: yesterday) { return "Yesterday" }
        let sameYear = calendar.component(.year, from: when) == calendar.component(.year, from: now)
        return format(when, sameYear ? "EEEEMMMMd" : "EEEEyMMMMd", calendar: calendar, locale: locale)
    }

    /// The ids of the items that start a new day — each gets a divider above it. The first
    /// item always does, so the reader always knows which day they're looking at.
    public static func dayBreaks(_ items: [ChatItem], calendar: Calendar = .current) -> Set<Int> {
        var breaks: Set<Int> = []
        var previous: Date?
        for item in items {
            guard let when = date(item.ts) else { continue }
            if previous.map({ !calendar.isDate($0, inSameDayAs: when) }) ?? true { breaks.insert(item.id) }
            previous = when
        }
        return breaks
    }

    /// The ids of the tool items that directly follow another tool item — each is drawn tight
    /// against the one above, so a run of calls reads as one group. A day divider breaks a run.
    public static func toolRunFollowers(_ items: [ChatItem], dayBreaks: Set<Int> = []) -> Set<Int> {
        var followers: Set<Int> = []
        var previousIsTool = false
        for item in items {
            let isTool: Bool
            if case .tool = item { isTool = true } else { isTool = false }
            if isTool, previousIsTool, !dayBreaks.contains(item.id) { followers.insert(item.id) }
            previousIsTool = isTool
        }
        return followers
    }
}
