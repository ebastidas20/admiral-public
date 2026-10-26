import Foundation

/// Pure transcript functions for the Anthropic endpoint: which user messages a
/// session has already seen (delta detection) and what assistant text a turn
/// produced (response capture). File IO stays with the caller — these take bytes.
public enum TurnCapture {

    // MARK: delta

    /// Ordered, trimmed text of every user message in the transcript. A user line's
    /// content may be a plain string or blocks; text blocks join with a blank line,
    /// tool_result and other non-text blocks contribute nothing.
    public static func userTexts(in data: Data) -> [String] {
        decodeLines(data).compactMap { raw in
            guard raw.type == "user", let content = raw.message?.content else { return nil }
            let text = textBlocks(of: content)
            return text.isEmpty ? nil : text
        }
    }

    /// Request user messages the session hasn't seen. A message is seen when its
    /// normalized text equals a transcript user text, or when it is part of a
    /// consecutive run whose blank-line join equals one (a prior multi-message
    /// injection lands as one joined transcript message — see the design spec).
    public static func unseen(requestTexts: [String], transcriptTexts: [String]) -> [String] {
        let seen = Set(transcriptTexts.map(normalize))
        var delta: [String] = []
        var i = 0
        while i < requestTexts.count {
            if seen.contains(normalize(requestTexts[i])) { i += 1; continue }
            if let runLength = joinedRunLength(from: i, in: requestTexts, seen: seen) {
                i += runLength
                continue
            }
            delta.append(requestTexts[i])
            i += 1
        }
        return delta
    }

    /// Longest run starting at `start` whose blank-line join is a seen transcript text.
    private static func joinedRunLength(from start: Int, in texts: [String], seen: Set<String>) -> Int? {
        var joined = normalize(texts[start])
        for end in (start + 1)..<texts.count {
            joined += "\n\n" + normalize(texts[end])
            if seen.contains(joined) { return end - start + 1 }
        }
        return nil
    }

    private static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: capture

    public struct Captured: Equatable {
        public var text: String
        public var usage: AnthropicUsage?
        /// Byte offset at the end of the last complete line consumed. Pass it back
        /// on the next poll so a line claude is mid-writing is never half-parsed.
        public var newOffset: Int
    }

    /// One `tool_use` block from an assistant line. `name` is whatever the transcript
    /// stored (`mcp__client__…` or the bare tool name).
    public struct ToolUse: Equatable, Sendable {
        public var id: String
        public var name: String
        public var input: JSONValue
        public init(id: String, name: String, input: JSONValue) {
            self.id = id
            self.name = name
            self.input = input
        }
    }

    /// `tool_use` blocks in complete assistant lines, in order. A block with no id is
    /// skipped — the HTTP response has to hand the client the transcript's `toolu_…` id.
    public static func toolUses(in data: Data) -> [ToolUse] {
        let newline = UInt8(ascii: "\n")
        guard let lastNewline = data.lastIndex(of: newline) else { return [] }
        var uses: [ToolUse] = []
        var seen = Set<String>()
        for raw in decodeLines(Data(data[...lastNewline])) where raw.type == "assistant" {
            guard let content = raw.message?.content else { continue }
            for block in content.blocks where block["type"]?.stringValue == "tool_use" {
                guard let id = block["id"]?.stringValue, !id.isEmpty, seen.insert(id).inserted else { continue }
                uses.append(ToolUse(id: id, name: block["name"]?.stringValue ?? "",
                                    input: block["input"] ?? .object([:])))
            }
        }
        return uses
    }

    /// Assistant text appended after `fromOffset`: text blocks of every complete
    /// assistant line, joined by blank lines; thinking and tool_use are skipped.
    /// Usage comes from the last assistant line that carries one.
    public static func capture(_ data: Data, fromOffset: Int) -> Captured {
        let newline = UInt8(ascii: "\n")
        guard fromOffset < data.count,
              let lastNewline = data[fromOffset...].lastIndex(of: newline) else {
            return Captured(text: "", usage: nil, newOffset: fromOffset)
        }
        let slice = data[fromOffset...lastNewline]
        var texts: [String] = []
        var usage: AnthropicUsage?
        for raw in decodeLines(Data(slice)) where raw.type == "assistant" {
            guard let content = raw.message?.content else { continue }
            let text = textBlocks(of: content)
            if !text.isEmpty { texts.append(text) }
            if let u = raw.message?.usage {
                usage = AnthropicUsage(inputTokens: u.inputTokens ?? 0, outputTokens: u.outputTokens ?? 0)
            }
        }
        return Captured(text: texts.joined(separator: "\n\n"), usage: usage, newOffset: lastNewline + 1)
    }

    // MARK: shared decoding

    private static func decodeLines(_ data: Data) -> [RawLine] {
        guard let content = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return content.split(separator: "\n", omittingEmptySubsequences: true).compactMap {
            guard let lineData = $0.data(using: .utf8) else { return nil }
            return try? decoder.decode(RawLine.self, from: lineData)
        }
    }

    /// Text blocks of string-or-array content, joined with a blank line, trimmed.
    private static func textBlocks(of content: JSONValue) -> String {
        content.blocks
            .filter { $0["type"]?.stringValue == "text" }
            .compactMap { $0["text"]?.stringValue }
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
