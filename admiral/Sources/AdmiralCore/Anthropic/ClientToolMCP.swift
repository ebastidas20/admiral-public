import Foundation
import Darwin

/// MCP JSON-RPC for the `client` server. The stdio process (`admiral-client-mcp`) is a
/// thin loop around `action(forLine:)` so a `tools/call` can be parked without the
/// stdin reader waiting — parallel tool calls in one assistant message all have to be
/// registered before any of them returns.
public enum ClientToolMCP {
    public enum Action: Equatable {
        case reply(Data)
        case park(id: JSONValue, name: String, arguments: JSONValue)
        case none
    }

    public static let serverName = "admiral-client"
    public static let protocolVersion = "2024-11-05"

    /// One stdin line. `tools` is the catalog as of this call (re-read the file each time).
    public static func action(forLine line: String, tools: [ClientToolSpec]) -> Action {
        guard let msg = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let method = msg["method"] as? String else { return .none }
        let id = msg["id"].map(jsonValue(from:))
        let params = msg["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            guard let id else { return .none }
            let version = params["protocolVersion"] as? String ?? protocolVersion
            return .reply(encode([
                "jsonrpc": "2.0", "id": foundation(id),
                "result": [
                    "protocolVersion": version,
                    "capabilities": ["tools": ["listChanged": true]],
                    "serverInfo": ["name": serverName, "version": "1.0.0"],
                ],
            ]))
        case "notifications/initialized", "initialized":
            return .none
        case "ping":
            guard let id else { return .none }
            return .reply(encode(["jsonrpc": "2.0", "id": foundation(id), "result": [String: Any]()]))
        case "tools/list":
            guard let id else { return .none }
            return .reply(encode([
                "jsonrpc": "2.0", "id": foundation(id),
                "result": ["tools": tools.map(mcpTool)],
            ]))
        case "tools/call":
            guard let id else { return .none }
            guard let name = params["name"] as? String, !name.isEmpty else {
                return .reply(rpcError(id: id, code: -32602, message: "tools/call requires a name"))
            }
            let arguments = params["arguments"].map(jsonValue(from:)) ?? .object([:])
            return .park(id: id, name: name, arguments: arguments == .null ? .object([:]) : arguments)
        default:
            guard let id else { return .none }
            return .reply(rpcError(id: id, code: -32601, message: "method not found: \(method)"))
        }
    }

    public static func callResult(id: JSONValue, result: ClientToolResult) -> Data {
        encode([
            "jsonrpc": "2.0", "id": foundation(id),
            "result": [
                "content": foundation(result.content),
                "isError": result.isError,
            ],
        ])
    }

    /// `notifications/tools/list_changed`. Claude Code re-fetches `tools/list` when this
    /// arrives on stdio. The catalog is also written before the tab is spawned, so the
    /// first `tools/list` is already the real names even if a build only honors
    /// `list_changed` on the newer protocol stream.
    public static func listChanged() -> Data {
        encode(["jsonrpc": "2.0", "method": "notifications/tools/list_changed"])
    }

    public static func rpcError(id: JSONValue, code: Int, message: String) -> Data {
        encode([
            "jsonrpc": "2.0", "id": foundation(id),
            "error": ["code": code, "message": message],
        ])
    }

    /// JSONSerialization value → `JSONValue`. `NSNumber` bridges to `Bool` as well as to
    /// numbers, so a boolean is recognized by CoreFoundation's boolean type id — otherwise
    /// `true` becomes `1` and no longer matches the transcript's canonical input.
    public static func jsonValue(from any: Any) -> JSONValue {
        if any is NSNull { return .null }
        if let text = any as? String { return .string(text) }
        if let number = any as? NSNumber {
            if CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            return .number(number.doubleValue)
        }
        if let items = any as? [Any] { return .array(items.map(jsonValue(from:))) }
        if let fields = any as? [String: Any] { return .object(fields.mapValues(jsonValue(from:))) }
        return .null
    }

    private static func mcpTool(_ spec: ClientToolSpec) -> [String: Any] {
        var tool: [String: Any] = [
            "name": spec.name,
            "inputSchema": foundation(spec.inputSchema),
        ]
        if !spec.description.isEmpty { tool["description"] = spec.description }
        return tool
    }

    private static func foundation(_ value: JSONValue) -> Any {
        AnthropicWire.foundationObject(value)
    }

    private static func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }
}

/// Stdio entry point for `admiral-client-mcp`. Reads MCP lines, parks `tools/call` on the
/// broker socket without blocking the next line, and emits `list_changed` when the
/// catalog file's mtime moves.
public enum ClientToolProcess {
    private static let outLock = NSLock()

    public static func main() {
        let env = ProcessInfo.processInfo.environment
        let token = env["ADMIRAL_SESSION"] ?? ""
        let socketPath = env["ADMIRAL_CLIENT_SOCKET"] ?? ""
        let catalogPath = env["ADMIRAL_CLIENT_CATALOG"] ?? ""
        let catalogURL = URL(fileURLWithPath: catalogPath)
        let client = ClientToolSocketClient(path: socketPath)
        if !socketPath.isEmpty { client.connect() }

        Task {
            var seen = ClientToolCatalog.revision(url: catalogURL)
            while true {
                try? await Task.sleep(nanoseconds: 500_000_000)
                let now = ClientToolCatalog.revision(url: catalogURL)
                guard now != seen else { continue }
                seen = now
                emit(ClientToolMCP.listChanged())
            }
        }

        Thread.detachNewThread {
            while let line = readLine(strippingNewline: true) {
                guard !line.isEmpty else { continue }
                switch ClientToolMCP.action(forLine: line, tools: ClientToolCatalog.read(url: catalogURL)) {
                case let .reply(data):
                    emit(data)
                case let .park(id, name, arguments):
                    Task {
                        let result: ClientToolResult
                        if client.isConnected {
                            result = await client.park(token: token, name: name, arguments: arguments)
                        } else {
                            result = .text("Admiral client tool broker is not connected", isError: true)
                        }
                        emit(ClientToolMCP.callResult(id: id, result: result))
                    }
                case .none:
                    break
                }
            }
            exit(0)
        }
        dispatchMain()
    }

    private static func emit(_ data: Data) {
        outLock.lock(); defer { outLock.unlock() }
        var line = data
        line.append(0x0A)
        FileHandle.standardOutput.write(line)
    }
}
