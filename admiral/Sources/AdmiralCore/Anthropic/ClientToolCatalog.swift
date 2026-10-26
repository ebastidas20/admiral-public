import Foundation

/// The client-tool catalog for one API tool tab, under `sessions/<token>/`.
/// The hook helper and the `client` MCP process both read these files; the endpoint
/// writes them. Same split as the structured-output tripwire.
public enum ClientToolCatalog {
    private struct File: Codable, Equatable {
        var tools: [ClientToolSpec]
    }

    /// Empty marker. Present from commission until the session dir is removed, so a
    /// later request that updates the catalog does not have to re-launch claude to
    /// count as an API tool tab.
    public static func isEnabled(base: URL, token: String) -> Bool {
        FileManager.default.fileExists(atPath: AdmiralPaths.clientToolModeFile(base: base, token: token).path)
    }

    @discardableResult
    public static func enable(base: URL, token: String) -> Bool {
        let url = AdmiralPaths.clientToolModeFile(base: base, token: token)
        do { try PrivateFile.write(Data(), to: url); return true } catch { return false }
    }

    public static func read(base: URL, token: String) -> [ClientToolSpec] {
        read(url: AdmiralPaths.clientToolsFile(base: base, token: token))
    }

    public static func read(url: URL) -> [ClientToolSpec] {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return file.tools
    }

    /// Writes the catalog. No-op when the canonical bytes would not change, so a repeat
    /// POST of the same `tools[]` does not bump the mtime the MCP process watches.
    @discardableResult
    public static func write(_ tools: [ClientToolSpec], base: URL, token: String) -> Bool {
        let url = AdmiralPaths.clientToolsFile(base: base, token: token)
        let file = File(tools: tools)
        guard let data = try? JSONEncoder().encode(file) else { return false }
        if let existing = try? Data(contentsOf: url),
           let old = try? JSONDecoder().decode(File.self, from: existing), old == file {
            return true
        }
        do { try PrivateFile.write(data, to: url); return true } catch { return false }
    }

    public static func contains(_ name: String, base: URL, token: String) -> Bool {
        let want = ClientToolNames.normalize(name)
        return read(base: base, token: token).contains { $0.name == want }
    }

    /// `UserPromptSubmit` context while this tab is an API tool tab. Nil for every
    /// other tab, so interactive sessions keep the goals reminder and nothing else.
    public static func promptContext(base: URL, token: String) -> String? {
        guard isEnabled(base: base, token: token) else { return nil }
        let tools = read(base: base, token: token)
        let lines = tools.map { spec -> String in
            let description = spec.description.trimmingCharacters(in: .whitespacesAndNewlines)
            return description.isEmpty ? "- \(spec.name)" : "- \(spec.name): \(description)"
        }
        let list = lines.isEmpty ? "(none registered)" : lines.joined(separator: "\n")
        return """
            ADMIRAL CLIENT TOOLS — call only these tools, on the `client` MCP server \
            (they appear as mcp__client__<name>). Their results come back from the user; \
            never invent a result. Built-in tools and every other MCP server are denied \
            on this tab.
            \(list)
            """
    }

    /// Hook stdout for that context. No `systemMessage`: the catalog is for the model,
    /// and a goals nag would point it at a tool this tab denies.
    public static func promptJSON(_ context: String) -> String {
        "{\"hookSpecificOutput\":{\"hookEventName\":\"UserPromptSubmit\","
            + "\"additionalContext\":\(JSONText.escaped(context))}}"
    }

    /// Seconds-resolution mtime the MCP process compares to notice a catalog change.
    public static func revision(url: URL) -> TimeInterval? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date else { return nil }
        return date.timeIntervalSince1970
    }
}
