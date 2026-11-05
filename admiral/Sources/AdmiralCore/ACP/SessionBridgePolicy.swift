import Foundation

/// When the app starts or stops the session bridge listener (:4142). The listener follows the
/// configured ACP agents — up while there is one, down when there are none — and the app asks
/// on every defaults change (any write, from anywhere). So a failed bind (the port is held,
/// e.g. by another Admiral) must not be retried on each of those: it is retried only once the
/// agent list differs from the one that failed, or once `retryInterval` has passed.
public struct SessionBridgePolicy: Sendable {
    public enum Action: Equatable, Sendable { case start, stop, none }

    public static let retryInterval: TimeInterval = 60

    private var failure: (agents: [AcpAgentConfig], at: Date)?

    public init() {}

    public func action(agents: [AcpAgentConfig], running: Bool, now: Date = Date()) -> Action {
        let wanted = !agents.isEmpty
        if running { return wanted ? .none : .stop }
        guard wanted else { return .none }
        if let failure, failure.agents == agents, now.timeIntervalSince(failure.at) < Self.retryInterval {
            return .none
        }
        return .start
    }

    /// The bind for `agents` failed at `now`: hold further attempts for that same list.
    public mutating func startFailed(agents: [AcpAgentConfig], now: Date = Date()) {
        failure = (agents, now)
    }

    /// The listener is up (or no longer wanted): nothing is held.
    public mutating func reset() { failure = nil }
}
