import Foundation

/// Persists the configured ACP agents in UserDefaults.
public final class AcpAgentStore {
    private let defaults: UserDefaults
    private let key = "admiral.acpAgents.v1"

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

    public func agent(named name: String) -> AcpAgentConfig? {
        load().first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}
