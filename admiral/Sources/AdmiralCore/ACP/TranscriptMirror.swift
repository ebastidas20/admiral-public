import Foundation

/// Writes what an ACP session shows into a local `.jsonl` in Claude Code's own transcript format,
/// so every transcript consumer (Chat, TabRun, TurnCapture, the SSE feed, plan folding) reads an
/// ACP tab unchanged.
///
/// Tool naming: ACP `kind` maps to the Claude tool the consumers already format (`read` → `Read`,
/// `edit` → `Edit`, `execute` → `Bash`, `search` → `Grep`, `fetch` → `WebFetch`); any other kind
/// uses the call's title. A `plan` update is a `TodoWrite` tool_use, which `PlanFolder` folds.
///
/// Message and thought chunks buffer until a boundary (tool call, plan, user line, `endTurn`) and
/// then land as ONE assistant line, so a chunk after a tool call starts a new line.
///
/// Contract: call `endTurn()` on EVERY turn exit (any stop reason, error, cancel, transport close).
/// It is idempotent (a second call writes nothing). `deinit` flushes pending text as a last resort.
/// Write errors are swallowed: a mirror that cannot write must never take the session down.
@MainActor
public final class TranscriptMirror {
    private let url: URL
    private let sessionID: String
    private let cwd: String
    /// Ordered runs of consecutive same-kind chunks, so thinking/text keep the order sent.
    private var runs: [(isThought: Bool, text: String)] = []
    private var lastUUID: String?
    private var toolNames: [String: String] = [:]
    private var pendingResults: [String: String] = [:]
    private var closedTools: Set<String> = []

    public static func url(base: URL, session: String) -> URL {
        base.appendingPathComponent("acp", isDirectory: true).appendingPathComponent("\(session).jsonl")
    }

    public init(url: URL, sessionID: String, cwd: String) {
        self.url = url
        self.sessionID = sessionID
        self.cwd = cwd
    }

    public func userPrompt(_ prompt: String) {
        flush()
        writeUser(.string(prompt))
    }

    public func endTurn() { flush() }

    public func apply(_ update: AcpUpdate) {
        switch update {
        case let .agentMessage(chunk): buffer(chunk, isThought: false)
        case let .agentThought(chunk): buffer(chunk, isThought: true)
        case let .userMessage(chunk):
            flush()
            writeUser(.string(chunk))
        case let .toolCall(id, title, kind, status, rawInput, _):
            flush()
            toolNames[id] = Self.toolName(kind: kind, title: title)
            writeAssistant([toolUse(id: id, name: toolNames[id] ?? title, input: rawInput ?? .object([:]))])
            if let status { finish(id: id, status: status) }
        case let .toolCallUpdate(id, status, content, _):
            if let content { pendingResults[id] = content }
            if let status { finish(id: id, status: status) }
        case let .plan(entries):
            flush()
            let todos = entries.map {
                JSONValue.object([
                    "content": .string($0.content),
                    "status": .string($0.status),
                    "activeForm": .string($0.content),
                ])
            }
            writeAssistant([toolUse(
                id: "plan-" + UUID().uuidString, name: "TodoWrite", input: .object(["todos": .array(todos)]))])
        case .availableCommands, .currentMode, .compaction, .unknown:
            break
        }
    }

    // MARK: - Building lines

    static func toolName(kind: String?, title: String) -> String {
        switch kind {
        case "read": "Read"
        case "edit": "Edit"
        case "execute": "Bash"
        case "search": "Grep"
        case "fetch": "WebFetch"
        default: title.isEmpty ? "tool" : title
        }
    }

    private func toolUse(id: String, name: String, input: JSONValue) -> JSONValue {
        .object(["type": .string("tool_use"), "id": .string(id), "name": .string(name), "input": input])
    }

    /// Writes the tool_result once a call reaches a terminal status (`completed` / `failed`).
    private func finish(id: String, status: String) {
        guard status == "completed" || status == "failed", closedTools.insert(id).inserted else { return }
        flush()
        let result: JSONValue = .object([
            "type": .string("tool_result"),
            "tool_use_id": .string(id),
            "content": .string(pendingResults.removeValue(forKey: id) ?? ""),
            "is_error": .bool(status == "failed"),
        ])
        writeUser(.array([result]))
    }

    private func buffer(_ chunk: String, isThought: Bool) {
        if let last = runs.last, last.isThought == isThought {
            runs[runs.count - 1].text += chunk
        } else {
            runs.append((isThought, chunk))
        }
    }

    private func flush() {
        let blocks: [JSONValue] = runs.filter { !$0.text.isEmpty }.map {
            $0.isThought
                ? .object(["type": .string("thinking"), "thinking": .string($0.text)])
                : .object(["type": .string("text"), "text": .string($0.text)])
        }
        runs = []
        if !blocks.isEmpty { writeAssistant(blocks) }
    }

    isolated deinit { flush() }

    private func writeAssistant(_ blocks: [JSONValue]) {
        write(type: "assistant", message: .object(["role": .string("assistant"), "content": .array(blocks)]))
    }

    private func writeUser(_ content: JSONValue) {
        write(type: "user", message: .object(["role": .string("user"), "content": content]))
    }

    private static let clock: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func write(type: String, message: JSONValue) {
        let uuid = UUID().uuidString
        let line: JSONValue = .object([
            "type": .string(type),
            "uuid": .string(uuid),
            "parentUuid": lastUUID.map(JSONValue.string) ?? .null,
            "sessionId": .string(sessionID),
            "cwd": .string(cwd),
            "timestamp": .string(Self.clock.string(from: Date())),
            "message": message,
        ])
        lastUUID = uuid
        append(line)
    }

    private func append(_ line: JSONValue) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var data = try? encoder.encode(line) else { return }
        data.append(UInt8(ascii: "\n"))
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // Best effort: the session carries on without a mirror line.
        }
    }
}
