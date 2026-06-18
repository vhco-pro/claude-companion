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

public struct RuleSpec: Decodable, Sendable {
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
}
