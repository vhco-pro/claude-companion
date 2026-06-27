import Foundation

// Compiled rule set the hook reads. The human-edited rules.yaml is compiled by the app into
// a fast rules.compiled.json (Foundation-decodable) so the hook needs NO YAML dependency.

public struct CompiledRules: Codable, Sendable {
    public var autoAccept: Bool
    public var deny: [Rule]
    public var ask: [Rule]
    /// User-set override exceptions. Evaluated AFTER deny + malicious-URL, BEFORE ask, so an
    /// `allow` can clear an `ask`/compromised match but can NEVER clear a hard deny or a
    /// malicious-URL block. Fed from rules.local.yaml; see allow-tier.spec.md.
    public var allow: [Rule]

    enum CodingKeys: String, CodingKey {
        case autoAccept = "auto_accept", deny, ask, allow
    }

    public init(autoAccept: Bool, deny: [Rule], ask: [Rule], allow: [Rule] = []) {
        self.autoAccept = autoAccept
        self.deny = deny
        self.ask = ask
        self.allow = allow
    }

    // Custom decode so a pre-allow-tier rules.compiled.json (no `allow` key) still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        autoAccept = try c.decode(Bool.self, forKey: .autoAccept)
        deny = try c.decode([Rule].self, forKey: .deny)
        ask = try c.decode([Rule].self, forKey: .ask)
        allow = try c.decodeIfPresent([Rule].self, forKey: .allow) ?? []
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
    /// Shown to the model as `permissionDecisionReason` on a deny. The reason is the ONLY signal
    /// the LLM gets, so it's written to stop silent workarounds and route the user into the loop.
    static let denyTail = "Do not attempt a workaround. If this is intended, ask the user to allow it (via the Claude Companion app)."
    static let denyGuidance = "Blocked by Claude Companion's safety guard (matched a deny rule). " + denyTail

    /// Decision flow (see permission-engine.spec.md + allow-tier.spec.md):
    /// auto-accept-off → ask; deny regex → deny; URL on malicious feed → deny; ALLOW exception →
    /// allow; ask regex → ask; URL on compromised feed → ask; else allow. First match wins.
    /// The allow tier sits after deny+malicious and before ask, so it clears an ask/compromised
    /// match but can never override a hard deny or a malicious-URL block.
    public static func evaluate(_ payload: HookPayload, rules: CompiledRules,
                                blocklist: Blocklist? = nil) -> Evaluation {
        guard rules.autoAccept else {
            return Evaluation(decision: .ask, ruleMatched: nil, reason: "auto-accept off")
        }

        // Hosts only extracted when a blocklist is present (the hook skips loading it otherwise).
        let hosts: [String] = blocklist == nil ? []
            : (payload.toolInput?.command).map(URLExtractor.hosts(in:)) ?? []

        if let r = firstMatch(payload, in: rules.deny) {
            return Evaluation(decision: .deny, ruleMatched: r, reason: Self.denyGuidance)
        }
        if let bl = blocklist {
            for h in hosts where bl.lookup(h) == .malicious {
                return Evaluation(decision: .deny, ruleMatched: "blocklist:\(h)",
                                  reason: "Blocked by Claude Companion: \(h) is on a known-malicious-domain feed. \(Self.denyTail)")
            }
        }
        if let r = firstMatch(payload, in: rules.allow) {
            return Evaluation(decision: .allow, ruleMatched: r, reason: "allowed by user exception")
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
