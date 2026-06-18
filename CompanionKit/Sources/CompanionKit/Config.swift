import CompanionCore
import Foundation
import Yams

/// App configuration (config.yaml). Foundation-owned keys only; features append their own.
/// Decoding is lenient - missing keys fall back to defaults so a partial/empty file still loads.
public struct AppConfig: Codable, Sendable, Equatable {
    public struct UI: Codable, Sendable, Equatable {
        public var statusFormat: String
        public init(statusFormat: String) { self.statusFormat = statusFormat }
        enum CodingKeys: String, CodingKey { case statusFormat = "status_format" }
        public init(from d: Decoder) throws {
            let c = try? d.container(keyedBy: CodingKeys.self)
            statusFormat = (try? c?.decodeIfPresent(String.self, forKey: .statusFormat)) ?? AppConfig.default.ui.statusFormat
        }
    }

    public var ui: UI
    public var logLevel: String
    public var blocklist: BlocklistConfig

    enum CodingKeys: String, CodingKey { case ui; case logLevel = "log_level"; case blocklist }

    public init(ui: UI, logLevel: String, blocklist: BlocklistConfig) {
        self.ui = ui
        self.logLevel = logLevel
        self.blocklist = blocklist
    }

    public init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        ui = (try? c?.decodeIfPresent(UI.self, forKey: .ui)) ?? AppConfig.default.ui
        logLevel = (try? c?.decodeIfPresent(String.self, forKey: .logLevel)) ?? AppConfig.default.logLevel
        blocklist = (try? c?.decodeIfPresent(BlocklistConfig.self, forKey: .blocklist)) ?? AppConfig.default.blocklist
    }

    public static let `default` = AppConfig(
        ui: UI(statusFormat: "◆ {weekly}% · 5h {fivehour}%"),
        logLevel: "info",
        blocklist: .default
    )
}

/// Threat-feed config for the URL/domain blocklist. Defaults ship a small reliable set; users
/// add more in config.yaml.
public struct BlocklistConfig: Codable, Sendable, Equatable {
    public struct Feed: Codable, Sendable, Equatable {
        public var name: String
        public var url: String
        public var format: String   // "domains" | "hosts" | "urls"
        public var cls: String      // "malicious" | "compromised"
        enum CodingKeys: String, CodingKey { case name, url, format; case cls = "class" }
        public init(name: String, url: String, format: String, cls: String) {
            self.name = name; self.url = url; self.format = format; self.cls = cls
        }
    }

    public var enabled: Bool
    public var feeds: [Feed]
    public var refreshMinutes: Int
    public var allowOverrides: [String]

    enum CodingKeys: String, CodingKey {
        case enabled, feeds
        case refreshMinutes = "refresh_minutes"
        case allowOverrides = "allow_overrides"
    }

    public init(enabled: Bool, feeds: [Feed], refreshMinutes: Int, allowOverrides: [String]) {
        self.enabled = enabled; self.feeds = feeds
        self.refreshMinutes = refreshMinutes; self.allowOverrides = allowOverrides
    }

    public init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c?.decodeIfPresent(Bool.self, forKey: .enabled)) ?? BlocklistConfig.default.enabled
        feeds = (try? c?.decodeIfPresent([Feed].self, forKey: .feeds)) ?? BlocklistConfig.default.feeds
        refreshMinutes = (try? c?.decodeIfPresent(Int.self, forKey: .refreshMinutes)) ?? BlocklistConfig.default.refreshMinutes
        allowOverrides = (try? c?.decodeIfPresent([String].self, forKey: .allowOverrides)) ?? BlocklistConfig.default.allowOverrides
    }

    public static let `default` = BlocklistConfig(
        enabled: true,
        feeds: [
            // URLhaus hostfile is reliable + small-ish; all entries treated malicious (the
            // compromised tier needs the tagged CSV - a later enhancement).
            Feed(name: "urlhaus", url: "https://urlhaus.abuse.ch/downloads/hostfile/", format: "hosts", cls: "malicious"),
        ],
        refreshMinutes: 360,
        allowOverrides: ["github.com", "raw.githubusercontent.com", "registry.npmjs.org", "pypi.org", "objects.githubusercontent.com"]
    )
}

/// Loads config.yaml and keeps the last-good value on malformed input.
public final class ConfigStore {
    public private(set) var config: AppConfig
    private let path: String

    public init(path: String = Paths.configFile) {
        self.path = path
        self.config = (try? Self.load(path)) ?? .default
    }

    public static func load(_ path: String) throws -> AppConfig {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        return try YAMLDecoder().decode(AppConfig.self, from: text)
    }

    /// Reload from disk; on failure keep the last-good config. Returns true if it changed.
    @discardableResult
    public func reload() -> Bool {
        guard let fresh = try? Self.load(path) else { return false }
        let changed = fresh != config
        config = fresh
        return changed
    }
}
