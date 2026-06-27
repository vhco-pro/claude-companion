import Foundation

// Human-facing rules.yaml model (app-side). The compiler maps this to CompanionCore's
// CompiledRules (rules.compiled.json) that the dependency-free hook reads. Lenient decode so a
// partial file still loads.

public struct RulesFile: Decodable, Sendable {
    public var autoAccept: Bool
    public var deny: [RuleSpec]
    public var ask: [RuleSpec]

    enum CodingKeys: String, CodingKey { case autoAccept = "auto_accept", deny, ask }

    public init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        autoAccept = (try? c?.decodeIfPresent(Bool.self, forKey: .autoAccept)) ?? true
        deny = (try? c?.decodeIfPresent([RuleSpec].self, forKey: .deny)) ?? []
        ask = (try? c?.decodeIfPresent([RuleSpec].self, forKey: .ask)) ?? []
    }
}

public struct RuleSpec: Codable, Sendable {
    public var tool: String?
    public var commandRegex: String?
    public var pathGlob: String?
    public var cwdGlob: String?

    enum CodingKeys: String, CodingKey {
        case tool
        case commandRegex = "command_regex"
        case pathGlob = "path_glob"
        case cwdGlob = "cwd_glob"
    }

    public init(tool: String? = nil, commandRegex: String? = nil,
                pathGlob: String? = nil, cwdGlob: String? = nil) {
        self.tool = tool
        self.commandRegex = commandRegex
        self.pathGlob = pathGlob
        self.cwdGlob = cwdGlob
    }

    /// Stable identity for matching against the `disabled:` list and for dedup. A rule is
    /// `tool|pattern`, where pattern is the command regex or path glob.
    public var identity: String {
        "\(tool ?? "*")|\(commandRegex ?? pathGlob ?? "")"
    }
}

/// Model for the app-owned `rules.local.yaml`: allow exceptions, user-added deny/ask, and a
/// `disabled:` list of shipped-rule identities to turn off. The app round-trips this struct↔YAML;
/// the shipped `rules.yaml` is never written by the app. Lenient decode so a partial file loads.
public struct LocalRulesFile: Codable, Sendable {
    public var allow: [RuleSpec]
    public var deny: [RuleSpec]
    public var ask: [RuleSpec]
    public var disabled: [String]

    enum CodingKeys: String, CodingKey { case allow, deny, ask, disabled }

    public init(allow: [RuleSpec] = [], deny: [RuleSpec] = [],
                ask: [RuleSpec] = [], disabled: [String] = []) {
        self.allow = allow
        self.deny = deny
        self.ask = ask
        self.disabled = disabled
    }

    public init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        allow = (try? c?.decodeIfPresent([RuleSpec].self, forKey: .allow)) ?? []
        deny = (try? c?.decodeIfPresent([RuleSpec].self, forKey: .deny)) ?? []
        ask = (try? c?.decodeIfPresent([RuleSpec].self, forKey: .ask)) ?? []
        disabled = (try? c?.decodeIfPresent([String].self, forKey: .disabled)) ?? []
    }
}
