import Foundation

/// In-memory copy of the operator token minted into the Keychain. The HTTP routes do not
/// read it — a missing token never fails a request. Swapping the value needs no server restart.
public final class OperatorTokenProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var current: String

    public init(_ initial: String = "") { current = initial }

    /// The stored token, `""` until Keychain resolution fills it.
    public var token: String {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }

    public var isAvailable: Bool { !token.isEmpty }
}
