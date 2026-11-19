import Foundation

/// A minimal, lenient JSON value used to read Claude's polymorphic transcript
/// blocks (where `content` is a string OR an array of typed blocks, and tool
/// `input` is arbitrary). Decoding never throws on shape — unknown shapes become
/// `.null` at the leaf rather than failing the whole line.
///
/// `Encodable` exists because a `HookEvent` carries one as `tool_input`, and graph
/// state must be `Codable`.
public enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            self = .null
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case let .bool(b): try c.encode(b)
        case let .number(n): try c.encode(n)
        case let .string(s): try c.encode(s)
        case let .array(a): try c.encode(a)
        case let .object(o): try c.encode(o)
        }
    }

    public subscript(_ key: String) -> JSONValue? {
        if case let .object(o) = self { return o[key] }
        return nil
    }

    public var stringValue: String? {
        if case let .string(s) = self { return s }
        return nil
    }

    public var boolValue: Bool? {
        if case let .bool(b) = self { return b }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case let .array(a) = self { return a }
        return nil
    }

    /// Flatten string-or-array content into plain text (used for tool_result content).
    public var asText: String {
        switch self {
        case let .string(s): return s
        case let .array(a): return a.map { $0["text"]?.stringValue ?? $0.asText }.joined()
        case .object: return self["text"]?.stringValue ?? ""
        default: return ""
        }
    }

    /// Normalize content into a list of blocks: an array stays as-is; a bare string
    /// becomes a single synthetic `text` block so callers branch in one place.
    public var blocks: [JSONValue] {
        switch self {
        case let .array(a): return a
        case let .string(s): return [.object(["type": .string("text"), "text": .string(s)])]
        default: return []
        }
    }
}
