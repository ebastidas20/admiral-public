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
/// A tool call that opens with no input (`rawInput` absent or `{}` — claude-agent-acp opens every
/// call that way and sends the input on its first update) is held until the input arrives, and
/// lands then; anything written before that (its result, a later line, `endTurn`) lands it first,
/// with what it has, so the order is the agent's.
///
/// A tool result carries a Claude-shaped `toolUseResult` beside its `message`, as claude's own
/// transcripts do: a call that sent a `diff` gets `{filePath, oldString, newString, type}`
/// (`type` "create" when there was no old text; of several diffs the last wins, since
/// claude-agent-acp sends the snippet first and the whole file last), and a call that ran in a
/// terminal gets `{stdout}` — the output streamed for it (the last 64 KB), else its text.
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
    private var diffs: [String: (path: String, oldText: String?, newText: String)] = [:]
    private var terminalCalls: Set<String> = []
    private var terminalOutput: [String: String] = [:]
    static let terminalOutputCap = 64 * 1024
    /// Tool calls waiting for their input, in arrival order (see the type's note).
    private var heldTools: [(id: String, name: String, input: JSONValue)] = []

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
            let name = Self.toolName(kind: kind, title: title)
            toolNames[id] = name
            let input = rawInput ?? .object([:])
            if Self.isEmpty(input) {
                heldTools.append((id, name, input))
            } else {
                writeAssistant([toolUse(id: id, name: name, input: input)])
            }
            if let status { finish(id: id, status: status) }
        case let .toolCallUpdate(id, status, content, _, rawInput, items):
            if let rawInput, !Self.isEmpty(rawInput), let i = heldTools.firstIndex(where: { $0.id == id }) {
                heldTools[i].input = rawInput
                writeHeldTools(through: i)
            }
            if let content { pendingResults[id] = content }
            for item in items {
                switch item {
                case let .diff(path, oldText, newText): diffs[id] = (path, oldText, newText)
                case .terminal: terminalCalls.insert(id)
                case .text: break
                }
            }
            if let status { finish(id: id, status: status) }
        case let .terminalOutput(id, data):
            guard !closedTools.contains(id) else { break }
            terminalCalls.insert(id)
            terminalOutput[id] = ((terminalOutput[id] ?? "") + data).utf8Tail(Self.terminalOutputCap)
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
        case .terminalExit, .availableCommands, .currentMode, .configOptions, .compaction, .unknown:
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

    private static func isEmpty(_ input: JSONValue) -> Bool {
        switch input {
        case .null: true
        case let .object(o): o.isEmpty
        default: false
        }
    }

    /// Lands the held calls up to and including `index` (all of them when nil), in order.
    private func writeHeldTools(through index: Int? = nil) {
        guard !heldTools.isEmpty else { return }
        let end = min(index ?? heldTools.count - 1, heldTools.count - 1)
        for held in heldTools[...end] { writeAssistant([toolUse(id: held.id, name: held.name, input: held.input)]) }
        heldTools.removeFirst(end + 1)
    }

    private func toolUse(id: String, name: String, input: JSONValue) -> JSONValue {
        .object(["type": .string("tool_use"), "id": .string(id), "name": .string(name), "input": input])
    }

    /// Writes the tool_result once a call reaches a terminal status (`completed` / `failed`).
    private func finish(id: String, status: String) {
        guard status == "completed" || status == "failed", closedTools.insert(id).inserted else { return }
        flush()
        let text = pendingResults.removeValue(forKey: id) ?? ""
        let result: JSONValue = .object([
            "type": .string("tool_result"),
            "tool_use_id": .string(id),
            "content": .string(text),
            "is_error": .bool(status == "failed"),
        ])
        writeUser(.array([result]), toolUseResult: toolUseResult(id: id, text: text))
    }

    /// The Claude-shaped structured result for a closing call (see the type's note); nil when it
    /// sent neither a diff nor terminal output. Forgets what it held for the call.
    private func toolUseResult(id: String, text: String) -> JSONValue? {
        let diff = diffs.removeValue(forKey: id)
        let output = terminalOutput.removeValue(forKey: id)
        let ranInTerminal = terminalCalls.remove(id) != nil
        if let diff {
            return .object([
                "filePath": .string(diff.path),
                "oldString": .string(diff.oldText ?? ""),
                "newString": .string(diff.newText),
                "type": .string(diff.oldText == nil ? "create" : "update"),
            ])
        }
        guard ranInTerminal else { return nil }
        return .object(["stdout": .string(output ?? text)])
    }

    private func buffer(_ chunk: String, isThought: Bool) {
        if let last = runs.last, last.isThought == isThought {
            runs[runs.count - 1].text += chunk
        } else {
            runs.append((isThought, chunk))
        }
    }

    private func flush() {
        // Held calls came before any text buffered since (a tool call flushes the text first).
        writeHeldTools()
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

    private func writeUser(_ content: JSONValue, toolUseResult: JSONValue? = nil) {
        write(type: "user", message: .object(["role": .string("user"), "content": content]),
              toolUseResult: toolUseResult)
    }

    private static let clock: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func write(type: String, message: JSONValue, toolUseResult: JSONValue? = nil) {
        let uuid = UUID().uuidString
        var fields: [String: JSONValue] = [
            "type": .string(type),
            "uuid": .string(uuid),
            "parentUuid": lastUUID.map(JSONValue.string) ?? .null,
            "sessionId": .string(sessionID),
            "cwd": .string(cwd),
            "timestamp": .string(Self.clock.string(from: Date())),
            "message": message,
        ]
        if let toolUseResult { fields["toolUseResult"] = toolUseResult }
        lastUUID = uuid
        append(.object(fields))
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

extension String {
    /// The last `maxBytes` of UTF-8 (whole characters only): output kept as a bounded tail.
    func utf8Tail(_ maxBytes: Int) -> String {
        let bytes = utf8
        guard bytes.count > maxBytes else { return self }
        var start = bytes.index(bytes.endIndex, offsetBy: -maxBytes)
        while start < bytes.endIndex, UTF8.isContinuation(bytes[start]) { start = bytes.index(after: start) }
        return String(decoding: bytes[start...], as: UTF8.self)
    }
}
