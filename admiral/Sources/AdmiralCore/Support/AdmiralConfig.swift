import Foundation

/// Versioned app config at `<support dir>/config.json` (see `AdmiralConfigStore.defaultURL`).
///
/// Loaded once at startup. Unknown keys are ignored (JSONDecoder default). Missing
/// feature keys fall back to `false`. The file is created with defaults when absent
/// so a fresh install has a stable place to flip flags later without a code change.
///
/// Tickets OAuth tokens are **not** stored here — only Keychain via `TicketsAuthStore`.
public struct AdmiralConfig: Codable, Equatable, Sendable {
    public var version: Int
    public var features: Features
    public var tickets: TicketsConfig

    public struct Features: Codable, Equatable, Sendable {
        public var chatView: Bool
        public var apiServer: Bool
        /// Group chats: tabs that share one conversation.
        public var groups: Bool
        /// The Dark theme's black becomes the dark blue of Stealth Browser's top bar.
        public var stealthTheme: Bool

        public init(chatView: Bool = false, apiServer: Bool = false, groups: Bool = false,
                    stealthTheme: Bool = false) {
            self.chatView = chatView
            self.apiServer = apiServer
            self.groups = groups
            self.stealthTheme = stealthTheme
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            chatView = try c.decodeIfPresent(Bool.self, forKey: .chatView) ?? false
            apiServer = try c.decodeIfPresent(Bool.self, forKey: .apiServer) ?? false
            groups = try c.decodeIfPresent(Bool.self, forKey: .groups) ?? false
            stealthTheme = try c.decodeIfPresent(Bool.self, forKey: .stealthTheme) ?? false
        }
    }

    /// Non-secret Tickets settings. Patterns detect keys in chat; the open-URL template
    /// builds browse links; `jira` holds the Atlassian site + OAuth client id only.
    public struct TicketsConfig: Codable, Equatable, Sendable {
        public var patterns: [String]
        public var openURLTemplate: String
        public var jira: JiraConnectorConfig

        public static let defaultPattern = #"(PROJ|ACME|KEY|OPS)-\d+\b"#

        public init(
            patterns: [String] = [defaultPattern],
            openURLTemplate: String = "",
            jira: JiraConnectorConfig = JiraConnectorConfig()
        ) {
            self.patterns = patterns
            self.openURLTemplate = openURLTemplate
            self.jira = jira
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let decoded = try c.decodeIfPresent([String].self, forKey: .patterns) ?? []
            patterns = decoded.isEmpty ? [Self.defaultPattern] : decoded
            openURLTemplate = try c.decodeIfPresent(String.self, forKey: .openURLTemplate) ?? ""
            jira = try c.decodeIfPresent(JiraConnectorConfig.self, forKey: .jira) ?? JiraConnectorConfig()
        }

        /// Browse URL for `key`: the template with `{key}` / `{KEY}` replaced. A template with
        /// neither is a site URL (`+ "/browse/{key}"`), and none at all falls back to
        /// `jira.siteURL`'s. Nil when neither is configured.
        public func openURL(for key: String) -> URL? {
            var template = openURLTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
            if template.isEmpty { template = jira.siteURL.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard !template.isEmpty else { return nil }
            if !template.contains("{key}") && !template.contains("{KEY}") {
                while template.hasSuffix("/") { template.removeLast() }
                template += "/browse/{key}"
            }
            let encoded = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
            return URL(string: template
                .replacingOccurrences(of: "{key}", with: encoded)
                .replacingOccurrences(of: "{KEY}", with: encoded))
        }
    }

    public struct JiraConnectorConfig: Codable, Equatable, Sendable {
        public var siteURL: String
        public var clientId: String

        public init(siteURL: String = "", clientId: String = "") {
            self.siteURL = siteURL
            self.clientId = clientId
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            siteURL = try c.decodeIfPresent(String.self, forKey: .siteURL) ?? ""
            clientId = try c.decodeIfPresent(String.self, forKey: .clientId) ?? ""
        }
    }

    public static let currentVersion = 1

    public static let `default` = AdmiralConfig(
        version: currentVersion,
        features: Features(chatView: false, apiServer: false),
        tickets: TicketsConfig()
    )

    public init(
        version: Int = currentVersion,
        features: Features = Features(),
        tickets: TicketsConfig = TicketsConfig()
    ) {
        self.version = version
        self.features = features
        self.tickets = tickets
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        features = try c.decodeIfPresent(Features.self, forKey: .features) ?? Features()
        tickets = try c.decodeIfPresent(TicketsConfig.self, forKey: .tickets) ?? TicketsConfig()
    }
}

/// Loads / saves `AdmiralConfig` from Admiral's own data folder.
public enum AdmiralConfigStore {
    /// `<support dir>/config.json` — `~/Library/Application Support/Admiral/config.json` (inside
    /// the app's container once Admiral is sandboxed), or the isolated `ADMIRAL_SUPPORT_DIR`, so
    /// a test or probe never edits the real config.
    public static var defaultURL: URL {
        AdmiralPaths.defaultSupportDir.appendingPathComponent("config.json")
    }

    /// Where the config lived before it moved into the support dir. Read only by
    /// `migrateLegacyFile`.
    public static var legacyURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/admiral/config.json")
    }

    /// One-time move of the old `~/.config/admiral/config.json` to `url`. Only when `url` doesn't
    /// exist yet (a config already there wins, and the old file is left alone), and never for an
    /// isolated support dir: that file belongs to the real install. Returns true when it moved.
    @discardableResult
    public static func migrateLegacyFile(from legacy: URL = legacyURL, to url: URL = defaultURL,
                                         isolated: Bool = AdmiralPaths.supportDirOverride != nil) -> Bool {
        let fm = FileManager.default
        guard !isolated, fm.fileExists(atPath: legacy.path), !fm.fileExists(atPath: url.path) else { return false }
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? fm.moveItem(at: legacy, to: url)) != nil else { return false }
        rmdir(legacy.deletingLastPathComponent().path)  // only removes the folder if now empty
        return true
    }

    /// Read config from `url`, creating the parent dir + defaults file when missing.
    /// Corrupt / unreadable files fall back to defaults without overwriting the file.
    public static func load(from url: URL = defaultURL) -> AdmiralConfig {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            save(.default, to: url)
            return .default
        }
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(AdmiralConfig.self, from: data)
        else { return .default }
        return config
    }

    /// Change one part of the config on disk and keep the rest as it is there — a Settings
    /// pane edits its own section without clobbering what another pane (or a hand edit)
    /// wrote. Returns what was saved.
    @discardableResult
    public static func update(at url: URL = defaultURL,
                              _ change: (inout AdmiralConfig) -> Void) -> AdmiralConfig {
        var config = load(from: url)
        change(&config)
        save(config, to: url)
        return config
    }

    public static func save(_ config: AdmiralConfig, to url: URL = defaultURL) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
