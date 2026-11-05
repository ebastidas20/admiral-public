import Foundation

/// Persists the configured ACP agents in UserDefaults.
public final class AcpAgentStore {
    private let defaults: UserDefaults
    private let key = "admiral.acpAgents.v1"

    private let defaultKey = "admiral.acpDefaultAgent.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> [AcpAgentConfig] {
        guard let data = defaults.data(forKey: key),
              let agents = try? JSONDecoder().decode([AcpAgentConfig].self, from: data)
        else { return [] }
        return agents
    }

    public func save(_ agents: [AcpAgentConfig]) {
        if let data = try? JSONEncoder().encode(agents) { defaults.set(data, forKey: key) }
    }

    /// The agent ⌘T's New-session form starts on; nil = Claude Code on this Mac.
    public var defaultAgentID: UUID? {
        get { defaults.string(forKey: defaultKey).flatMap(UUID.init(uuidString:)) }
        set { defaults.set(newValue?.uuidString, forKey: defaultKey) }
    }

    /// The default agent while it is still configured; a deleted one reads as nil.
    public func defaultAgent() -> AcpAgentConfig? {
        guard let id = defaultAgentID else { return nil }
        return load().first { $0.id == id }
    }

    public func agent(named name: String) -> AcpAgentConfig? {
        load().first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}
