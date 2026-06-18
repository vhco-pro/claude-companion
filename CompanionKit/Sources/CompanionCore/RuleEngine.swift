import Foundation

// Compiled rule set the hook reads. The human-edited rules.yaml is compiled by the app into
// a fast rules.compiled.json (Foundation-decodable) so the hook needs NO YAML dependency.

public struct CompiledRules: Codable, Sendable {
    public var autoAccept: Bool
    public var deny: [Rule]
    public var ask: [Rule]

    enum CodingKeys: String, CodingKey {
        case autoAccept = "auto_accept", deny, ask
    }

    public init(autoAccept: Bool, deny: [Rule], ask: [Rule]) {
        self.autoAccept = autoAccept
        self.deny = deny
        self.ask = ask
    }
}

public struct Rule: Codable, Sendable {
    public let tool: String?
    public let commandRegex: String?
    public let pathGlob: String?

    enum CodingKeys: String, CodingKey {
        case tool
        case commandRegex = "command_regex"
        case pathGlob = "path_glob"
    }

    public init(tool: String? = nil, commandRegex: String? = nil, pathGlob: String? = nil) {
        self.tool = tool
        self.commandRegex = commandRegex
        self.pathGlob = pathGlob
    }
}

public struct Evaluation: Sendable {
    public let decision: PermissionDecision
    public let ruleMatched: String?
    public let reason: String?
}

public enum RuleEngine {
    /// Decision flow (see permission-engine.spec.md):
    /// auto-accept-off → ask; deny regex → deny; URL on malicious feed → deny; ask regex → ask;
    /// URL on compromised feed → ask; else allow. First match wins; deny > ask > allow.
    public static func evaluate(_ payload: HookPayload, rules: CompiledRules,
                                blocklist: Blocklist? = nil) -> Evaluation {
        guard rules.autoAccept else {
            return Evaluation(decision: .ask, ruleMatched: nil, reason: "auto-accept off")
        }

        // Hosts only extracted when a blocklist is present (the hook skips loading it otherwise).
        let hosts: [String] = blocklist == nil ? []
            : (payload.toolInput?.command).map(URLExtractor.hosts(in:)) ?? []

        if let r = firstMatch(payload, in: rules.deny) {
            return Evaluation(decision: .deny, ruleMatched: r, reason: "blocked by deny rule")
        }
        if let bl = blocklist {
            for h in hosts where bl.lookup(h) == .malicious {
                return Evaluation(decision: .deny, ruleMatched: "blocklist:\(h)",
                                  reason: "known-malicious domain: \(h)")
            }
        }
        if let r = firstMatch(payload, in: rules.ask) {
            return Evaluation(decision: .ask, ruleMatched: r, reason: "flagged for review")
        }
        if let bl = blocklist {
            for h in hosts where bl.lookup(h) == .compromised {
                return Evaluation(decision: .ask, ruleMatched: "blocklist:\(h)",
                                  reason: "normally-trusted domain currently flagged as compromised: \(h)")
            }
        }
        return Evaluation(decision: .allow, ruleMatched: nil, reason: nil)
    }

    static func firstMatch(_ payload: HookPayload, in rules: [Rule]) -> String? {
        for rule in rules {
            if let tool = rule.tool, tool != payload.toolName { continue }
            if let pattern = rule.commandRegex, let cmd = payload.toolInput?.command,
               regexMatches(pattern, cmd) {
                return pattern
            }
            if let glob = rule.pathGlob, let path = payload.toolInput?.filePath,
               fnmatch(glob, path, 0) == 0 {
                // NOTE: fnmatch does not honor "**"; the app compiles ** globs to explicit
                // patterns (or we swap to a glob→regex compile) in the permission-engine phase.
                return glob
            }
        }
        return nil
    }

    static func regexMatches(_ pattern: String, _ text: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return false }
        return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
