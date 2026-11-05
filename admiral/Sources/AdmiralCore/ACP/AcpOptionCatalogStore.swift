import Foundation

/// The config options each agent last advertised, per agent id — what Settings → Agents lists
/// as "Starting options". Saved on every session start, so it follows the agent (a mode that
/// disappears when the container user is root disappears here too).
public final class AcpOptionCatalogStore {
    private let defaults: UserDefaults
    private let key = "admiral.acpOptionCatalog.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load(agentID: UUID) -> [AcpConfigOption] {
        all()[agentID.uuidString] ?? []
    }

    public func save(_ options: [AcpConfigOption], agentID: UUID) {
        var catalog = all()
        catalog[agentID.uuidString] = options
        if let data = try? JSONEncoder().encode(catalog) { defaults.set(data, forKey: key) }
    }

    private func all() -> [String: [AcpConfigOption]] {
        guard let data = defaults.data(forKey: key),
              let catalog = try? JSONDecoder().decode([String: [AcpConfigOption]].self, from: data)
        else { return [:] }
        return catalog
    }
}
