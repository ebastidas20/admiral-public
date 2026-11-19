import Foundation

/// The environment an ACP agent, and a command run in its environment (`ExecCommandRunner`),
/// is launched with on this Mac.
///
/// A Finder-launched Admiral inherits launchd's `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`), so
/// `/usr/bin/env docker` finds no `/usr/local/bin/docker` and exits 127. `swift test` never
/// sees it: tests inherit the terminal's `PATH`. The one decision of which `PATH` wins:
/// the agent's own `env["PATH"]`, else the user's login-shell `PATH`, else the inherited one
/// with the usual Homebrew/local dirs appended.
public enum LaunchEnvironment {
    /// Appended to the inherited `PATH` when the login shell could not be read.
    public static let fallbackDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]
    static let launchdPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// `base` with `overrides` merged over it, and `PATH` decided as above.
    public static func make(
        base: [String: String],
        overrides: [String: String],
        loginPath: () -> String?
    ) -> [String: String] {
        var env = base.merging(overrides) { _, new in new }
        env["PATH"] = path(configured: overrides["PATH"], loginPath: loginPath, inherited: base["PATH"])
        return env
    }

    public static func path(configured: String?, loginPath: () -> String?, inherited: String?) -> String {
        if let configured = nonEmpty(configured) { return configured }
        if let login = nonEmpty(loginPath()) { return login }
        var dirs = (nonEmpty(inherited) ?? launchdPath).split(separator: ":").map(String.init)
        for dir in fallbackDirectories where !dirs.contains(dir) { dirs.append(dir) }
        return dirs.joined(separator: ":")
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

/// The user's login-shell `PATH`, read once per process (`GitHubEnvironment.loginEnvValue`
/// spawns an interactive login zsh) on a background queue and cached.
///
/// `current()` never blocks: until the shell has answered it returns nil (the launch then
/// takes `LaunchEnvironment`'s fallback) and starts the read if nobody has. `prewarm()` starts
/// it early — the app calls it at launch, so a tab opened later gets the real `PATH`.
public final class LoginShellPath: @unchecked Sendable {
    public static let shared = LoginShellPath { GitHubEnvironment.loginEnvValue("PATH") }

    private enum State { case idle, resolving, resolved(String?) }
    private let lock = NSLock()
    private var state = State.idle
    private let read: @Sendable () -> String?

    public init(read: @escaping @Sendable () -> String?) {
        self.read = read
    }

    public func prewarm() { _ = current() }

    public func current() -> String? {
        let start: Bool = lock.withLock {
            guard case .idle = state else { return false }
            state = .resolving
            return true
        }
        if start {
            DispatchQueue.global(qos: .utility).async { [self] in
                let value = read()
                lock.withLock { state = .resolved(value) }
            }
        }
        return lock.withLock {
            if case let .resolved(value) = state { return value }
            return nil
        }
    }
}
