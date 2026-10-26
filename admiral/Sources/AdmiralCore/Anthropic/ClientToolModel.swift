import Foundation

/// Names and limits for the `client` MCP server an API tool tab exposes.
public enum ClientToolNames {
    /// MCP server key in `--mcp-config`. Claude Code calls its tools `mcp__client__<name>`.
    public static let server = "client"
    public static let mcpPrefix = "mcp__client__"

    /// The tool name the HTTP client registered, whether the transcript stored the MCP
    /// prefix or the bare name.
    public static func normalize(_ name: String) -> String {
        name.hasPrefix(mcpPrefix) ? String(name.dropFirst(mcpPrefix.count)) : name
    }
}

/// How long the `client` MCP server may sit inside one `tools/call`.
/// Claude Code reads `timeout` as milliseconds and ignores a value below 1000, so this
/// is the Anthropic turn cap (600s) in milliseconds — also `>=` 600 if a build treated
/// the field as seconds.
public enum ClientToolLimits {
    public static let mcpTimeoutMilliseconds = 600_000
}

/// One tool a Messages client registered on `POST /v1/messages`.
public struct ClientToolSpec: Equatable, Sendable, Codable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue

    public init(name: String, description: String = "", inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

/// What fulfilling a park hands back to Claude through the MCP `tools/call` result.
public struct ClientToolResult: Equatable, Sendable {
    public var isError: Bool
    public var content: JSONValue

    public init(isError: Bool, content: JSONValue) {
        self.isError = isError
        self.content = content
    }

    public static func text(_ text: String, isError: Bool = false) -> ClientToolResult {
        ClientToolResult(isError: isError, content: .array([
            .object(["type": .string("text"), "text": .string(text)]),
        ]))
    }

    /// Anthropic `tool_result.content`: a string becomes one text block; an array is
    /// passed through as MCP content blocks.
    public static func from(content: JSONValue, isError: Bool) -> ClientToolResult {
        switch content {
        case let .string(text):
            return .text(text, isError: isError)
        case .array:
            return ClientToolResult(isError: isError, content: content)
        case .null:
            return .text("", isError: isError)
        default:
            return .text(CanonicalJSON.string(content), isError: isError)
        }
    }

    /// Text of the content blocks, for tests and error strings.
    public var text: String {
        guard case let .array(blocks) = content else { return content.asText }
        let joined = blocks.compactMap { $0["text"]?.stringValue }.joined()
        return joined.isEmpty ? content.asText : joined
    }
}

/// One `tool_result` block on the continuation request.
public struct ClientToolResultBlock: Equatable, Sendable {
    public var toolUseID: String
    public var result: ClientToolResult

    public init(toolUseID: String, result: ClientToolResult) {
        self.toolUseID = toolUseID
        self.result = result
    }
}

/// A park the HTTP layer can see. `toolUseID` is nil until the transcript's `toolu_…`
/// id has been matched onto it.
public struct ClientToolParkView: Equatable, Sendable {
    public var name: String
    public var toolUseID: String?

    public init(name: String, toolUseID: String?) {
        self.name = name
        self.toolUseID = toolUseID
    }
}

/// What a continuation may do while parks are outstanding.
public enum ClientToolContinuationDecision: Equatable, Sendable {
    /// The tool_result set is exactly the outstanding tool_use ids.
    case match([ClientToolResultBlock])
    case reject(String)
}

public enum ClientToolContinuation {
    public static let plainTextRefusal =
        "a client tool call is outstanding; send tool_result for each tool_use id and no user text"
    public static let uncorrelatedRefusal =
        "a client tool call is outstanding but not yet reported"
    public static let noneOutstanding = "no client tool call is outstanding"

    /// `outstanding` is every park still waiting. A match requires each park to already
    /// carry its transcript id, and the tool_result ids to be that set exactly — no
    /// subset, no extras, no user text alongside them.
    public static func decide(
        outstanding: [ClientToolParkView],
        results: [ClientToolResultBlock],
        lastUserMessageHasText: Bool
    ) -> ClientToolContinuationDecision {
        if outstanding.contains(where: { $0.toolUseID == nil }) {
            return .reject(uncorrelatedRefusal)
        }
        if lastUserMessageHasText {
            return .reject(plainTextRefusal)
        }
        let expected = outstanding.compactMap(\.toolUseID)
        let got = results.map(\.toolUseID)
        guard Set(got).count == got.count, Set(got) == Set(expected), got.count == expected.count else {
            return .reject(mismatch(expected: expected, got: got))
        }
        return .match(results)
    }

    static func mismatch(expected: [String], got: [String]) -> String {
        let want = expected.sorted().joined(separator: ", ")
        let have = got.sorted().joined(separator: ", ")
        return "tool_result ids must match the outstanding tool_use ids exactly "
            + "(expected \(want); got \(have))"
    }
}

/// Compact JSON with object keys sorted, so a transcript `input` and an MCP `arguments`
/// object match regardless of key order. Whole numbers encode as integers (`1`, not `1.0`).
public enum CanonicalJSON {
    public static func string(_ value: JSONValue) -> String { encode(value) }

    private static func encode(_ value: JSONValue) -> String {
        switch value {
        case .null: return "null"
        case let .bool(flag): return flag ? "true" : "false"
        case let .number(number): return encodeNumber(number)
        case let .string(text): return JSONText.escaped(text)
        case let .array(items): return "[" + items.map(encode).joined(separator: ",") + "]"
        case let .object(fields):
            let body = fields.keys.sorted().map { key in
                JSONText.escaped(key) + ":" + encode(fields[key] ?? .null)
            }.joined(separator: ",")
            return "{" + body + "}"
        }
    }

    private static func encodeNumber(_ number: Double) -> String {
        guard number.isFinite else { return "null" }
        if number == 0 { return "0" }
        if number.rounded() == number, abs(number) < 9_007_199_254_740_992 {
            return String(Int64(number))
        }
        let data = (try? JSONSerialization.data(withJSONObject: [number])) ?? Data("[0]".utf8)
        let text = String(decoding: data, as: UTF8.self)
        return String(text.dropFirst().dropLast())
    }
}
