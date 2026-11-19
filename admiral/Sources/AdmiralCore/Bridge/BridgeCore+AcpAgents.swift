import Foundation

/// The fields an `add_acp_agent` / `edit_acp_agent` call sets. nil = not given: an add takes the
/// config's default, an edit keeps the current value. An empty list or map given explicitly
/// clears it.
public struct AcpAgentChanges: Equatable, Sendable {
    public var name: String?
    public var transport: AcpTransportKind?
    public var command: String?
    public var args: [String]?
    public var url: String?
    public var env: [String: String]?
    public var cwd: String?
    /// "this_mac" or "elsewhere".
    public var runsOn: String?
    /// Elsewhere only: command then args. Empty = none.
    public var exec: [String]?
    public var bridgeURL: String?
    public var sessionMeta: [String: JSONValue]?
    public var startingOptions: [String: String]?

    public init() {}
}

/// Settings → Agents over the bridge: list, add, edit and delete the configured ACP agents.
/// Saves go through the same checks as the Settings form (`validationErrors(among:openTabAgents:)`,
/// `deletionError`), so a rename or delete with a tab open is refused here too.
extension BridgeCore {
    /// Names of the agents open tabs run on (a rename or delete would orphan them).
    private var openTabAgentNames: [String] {
        manager.sessions.compactMap {
            if case let .acp(name) = $0.backend { return name }
            return nil
        }
    }

    public func listAcpAgents() -> BridgeResult {
        let agents = manager.acpAgents()
        guard !agents.isEmpty else { return .success("(no ACP agents configured)") }
        return .success(agents.map(Self.describe).joined(separator: "\n"))
    }

    public func addAcpAgent(_ changes: AcpAgentChanges) -> BridgeResult {
        guard let save = saveAcpAgents else { return .failure("ACP agents can't be saved here") }
        guard let name = changes.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            return .failure("name is required")
        }
        var config = AcpAgentConfig(name: name, launch: AcpCommand(command: ""), cwd: "")
        if let problem = Self.apply(changes, to: &config, isNew: true) { return .failure(problem) }
        var agents = manager.acpAgents()
        let errors = config.validationErrors(among: agents, openTabAgents: openTabAgentNames)
        guard errors.isEmpty else { return .failure("not added: " + errors.joined(separator: "; ")) }
        agents.append(config)
        save(agents)
        return .success("added " + Self.describe(config))
    }

    public func editAcpAgent(named name: String, _ changes: AcpAgentChanges) -> BridgeResult {
        guard let save = saveAcpAgents else { return .failure("ACP agents can't be saved here") }
        var agents = manager.acpAgents()
        guard let i = agents.firstIndex(where: { AcpAgentConfig.sameName($0.name, name) }) else {
            return .failure("no ACP agent named \u{201C}\(name)\u{201D}")
        }
        var config = agents[i]
        if let problem = Self.apply(changes, to: &config, isNew: false) { return .failure(problem) }
        let errors = config.validationErrors(among: agents, openTabAgents: openTabAgentNames)
        guard errors.isEmpty else { return .failure("not saved: " + errors.joined(separator: "; ")) }
        agents[i] = config
        save(agents)
        return .success("saved " + Self.describe(config) + " (applies to new tabs)")
    }

    public func deleteAcpAgent(named name: String) -> BridgeResult {
        guard let save = saveAcpAgents else { return .failure("ACP agents can't be saved here") }
        var agents = manager.acpAgents()
        guard let agent = agents.first(where: { AcpAgentConfig.sameName($0.name, name) }) else {
            return .failure("no ACP agent named \u{201C}\(name)\u{201D}")
        }
        if let reason = agent.deletionError(openTabAgents: openTabAgentNames) { return .failure(reason) }
        agents.removeAll { $0.id == agent.id }
        save(agents)
        return .success("deleted \(agent.name)")
    }

    /// Applies `changes`; returns a problem the config's own validation can't express.
    static func apply(_ c: AcpAgentChanges, to config: inout AcpAgentConfig, isNew: Bool) -> String? {
        if let name = c.name { config.name = name.trimmingCharacters(in: .whitespaces) }
        if let transport = c.transport { config.transport = transport }
        if let command = c.command { config.launch.command = command.trimmingCharacters(in: .whitespaces) }
        if let args = c.args { config.launch.args = args }
        if let url = c.url { config.url = url.trimmingCharacters(in: .whitespaces) }
        if let env = c.env { config.env = env }
        if let cwd = c.cwd { config.cwd = cwd.trimmingCharacters(in: .whitespaces) }
        if let meta = c.sessionMeta { config.sessionMeta = meta }
        if let options = c.startingOptions { config.defaultConfigOptions = options }

        let wasThisMac = config.workspace == .thisMac
        var runsElsewhere = !wasThisMac
        if let runsOn = c.runsOn {
            switch runsOn {
            case "this_mac": runsElsewhere = false
            case "elsewhere": runsElsewhere = true
            default: return "runs_on must be this_mac or elsewhere (got \u{201C}\(runsOn)\u{201D})"
            }
        }
        if runsElsewhere {
            let exec = c.exec ?? config.execRunnerCommand.map { [$0.command] + $0.args } ?? []
            config.workspace = .elsewhere(exec: exec.first.map { AcpCommand(command: $0, args: Array(exec.dropFirst())) })
            if let bridge = c.bridgeURL {
                config.mcpCallbackURL = bridge.trimmingCharacters(in: .whitespaces)
            } else if wasThisMac || isNew {
                // This Mac's loopback URL would not reach the Mac from elsewhere.
                config.mcpCallbackURL = ""
            }
        } else {
            if c.exec?.isEmpty == false { return "exec applies only when runs_on is elsewhere" }
            config.workspace = .thisMac
            config.mcpCallbackURL = AcpAgentConfig.defaultCallbackURL(for: .thisMac)
        }
        return nil
    }

    static func describe(_ a: AcpAgentConfig) -> String {
        let runs: String = switch a.workspace {
        case .thisMac: "this_mac"
        case let .elsewhere(exec): "elsewhere" + (exec.map { " exec=\(([$0.command] + $0.args).joined(separator: " "))" } ?? "")
        }
        var line = "\(a.name) [\(a.transport == .stdio ? "stdio" : "websocket")] \(a.connectionLabel) cwd=\(a.cwd) runs_on=\(runs)"
        if case .elsewhere = a.workspace { line += " bridge_url=\(a.mcpCallbackURL)" }
        if !a.sessionMeta.isEmpty { line += " session_meta=\(AcpAgentDraft.metaText(a.sessionMeta))" }
        if !a.defaultConfigOptions.isEmpty {
            line += " starting_options=" + a.defaultConfigOptions.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        }
        if !a.env.isEmpty { line += " env=" + a.env.keys.sorted().joined(separator: ",") }
        return line
    }
}
