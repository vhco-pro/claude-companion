import Foundation

// Compiled rule set the hook reads. The human-edited rules.yaml is compiled by the app into
// a fast rules.compiled.json (Foundation-decodable) so the hook needs NO YAML dependency.

public struct CompiledRules: Codable, Sendable {
    public var autoAccept: Bool
    public var deny: [Rule]
    public var ask: [Rule]
    /// User-set override exceptions. Evaluated AFTER deny + malicious-URL, BEFORE confirm/ask, so an
    /// `allow` can clear an `ask`/`confirm`/compromised match but can NEVER clear a hard deny or a
    /// malicious-URL block. Fed from rules.local.yaml; see allow-tier.spec.md.
    public var allow: [Rule]
    /// Human-override tier: a serious-but-reversible operation held for explicit per-invocation
    /// human approval. Compiles down to a returned `ask` (the model can never self-approve; the
    /// hook stays instant/standalone), distinct from routine `ask` only in messaging/audit. Also
    /// the landing tier for a `remote_overridable` deny downgraded under a remote-exec wrapper.
    /// See human-override-remote-awareness.spec.md.
    public var confirm: [Rule]

    enum CodingKeys: String, CodingKey {
        case autoAccept = "auto_accept", deny, ask, allow, confirm
    }

    public init(autoAccept: Bool, deny: [Rule], ask: [Rule], allow: [Rule] = [], confirm: [Rule] = []) {
        self.autoAccept = autoAccept
        self.deny = deny
        self.ask = ask
        self.allow = allow
        self.confirm = confirm
    }

    // Custom decode so a pre-allow-tier/pre-confirm-tier rules.compiled.json (no `allow`/`confirm`
    // key) still loads unchanged - both default to empty.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        autoAccept = try c.decode(Bool.self, forKey: .autoAccept)
        deny = try c.decode([Rule].self, forKey: .deny)
        ask = try c.decode([Rule].self, forKey: .ask)
        allow = try c.decodeIfPresent([Rule].self, forKey: .allow) ?? []
        confirm = try c.decodeIfPresent([Rule].self, forKey: .confirm) ?? []
    }
}

public struct Rule: Codable, Sendable {
    public let tool: String?
    public let commandRegex: String?
    public let pathGlob: String?
    /// Marks a `deny` rule as "local-filesystem concern, safe to soften to a human checkpoint when
    /// the action provably runs on a REMOTE host." When set and the command is a remote-exec wrapper
    /// (`RemoteExec.isRemoteExec`), the engine returns `ask` (confirm) instead of `deny`. Catastrophic
    /// host-agnostic rules (rm -rf /, mkfs, dd of=disk, fork bomb, sudoers) are never tagged.
    public let remoteOverridable: Bool?

    enum CodingKeys: String, CodingKey {
        case tool
        case commandRegex = "command_regex"
        case pathGlob = "path_glob"
        case remoteOverridable = "remote_overridable"
    }

    public init(tool: String? = nil, commandRegex: String? = nil, pathGlob: String? = nil,
                remoteOverridable: Bool? = nil) {
        self.tool = tool
        self.commandRegex = commandRegex
        self.pathGlob = pathGlob
        self.remoteOverridable = remoteOverridable
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
    /// Shown on a `confirm` match: hard-stops the model but routes to the human's native approval.
    static let confirmGuidance = "Held by Claude Companion for explicit human approval (override checkpoint). Approve only if you intend this serious-but-reversible operation."
    /// Shown when a `remote_overridable` deny is softened because the action runs on a remote host.
    static let remoteOverrideGuidance = "Held for human approval: a local-filesystem safety rule matched, but this runs on a REMOTE host (ssm/ssh), so it targets that box, not this machine. Approve only if intended."

    /// Decision flow (see permission-engine.spec.md + allow-tier.spec.md +
    /// human-override-remote-awareness.spec.md):
    /// auto-accept-off → ask; deny regex → deny (a `remote_overridable` deny under a remote-exec
    /// wrapper → ask/confirm instead); URL on malicious feed → deny; ALLOW exception → allow;
    /// confirm regex → ask; ask regex → ask; URL on compromised feed → ask; else allow. First match
    /// wins. Allow sits after deny+malicious and before confirm/ask, so it clears an
    /// ask/confirm/compromised match but can never override a hard deny or a malicious-URL block.
    public static func evaluate(_ payload: HookPayload, rules: CompiledRules,
                                blocklist: Blocklist? = nil) -> Evaluation {
        guard rules.autoAccept else {
            return Evaluation(decision: .ask, ruleMatched: nil, reason: "auto-accept off")
        }

        // Hosts only extracted when a blocklist is present (the hook skips loading it otherwise).
        let hosts: [String] = blocklist == nil ? []
            : (payload.toolInput?.command).map(URLExtractor.hosts(in:)) ?? []

        // Match command rules against the sanitized command so a flagged pattern inside quoted DATA
        // or a comment doesn't false-positive (CommandSanitizer returns the original unchanged when
        // any execution-capable construct is present, so real threats are never masked).
        let cmd = payload.toolInput?.command.map(CommandSanitizer.forMatching)

        if let r = firstMatch(payload, command: cmd, in: rules.deny) {
            // A local-fs deny that runs on a remote host is softened to a human checkpoint - the
            // path targets the remote box, not this Mac. Remote-exec detection uses the RAW command
            // (the ssm/ssh wrapper is real execution structure, never quoted data).
            if r.remoteOverridable == true,
               let raw = payload.toolInput?.command, RemoteExec.isRemoteExec(raw) {
                return Evaluation(decision: .ask, ruleMatched: patternOf(r), reason: Self.remoteOverrideGuidance)
            }
            return Evaluation(decision: .deny, ruleMatched: patternOf(r), reason: Self.denyGuidance)
        }
        if let bl = blocklist {
            for h in hosts where bl.lookup(h) == .malicious {
                return Evaluation(decision: .deny, ruleMatched: "blocklist:\(h)",
                                  reason: "Blocked by Claude Companion: \(h) is on a known-malicious-domain feed. \(Self.denyTail)")
            }
        }
        if let r = firstMatch(payload, command: cmd, in: rules.allow) {
            return Evaluation(decision: .allow, ruleMatched: patternOf(r), reason: "allowed by user exception")
        }
        if let r = firstMatch(payload, command: cmd, in: rules.confirm) {
            return Evaluation(decision: .ask, ruleMatched: patternOf(r), reason: Self.confirmGuidance)
        }
        if let r = firstMatch(payload, command: cmd, in: rules.ask) {
            return Evaluation(decision: .ask, ruleMatched: patternOf(r), reason: "flagged for review")
        }
        if let bl = blocklist {
            for h in hosts where bl.lookup(h) == .compromised {
                return Evaluation(decision: .ask, ruleMatched: "blocklist:\(h)",
                                  reason: "normally-trusted domain currently flagged as compromised: \(h)")
            }
        }
        return Evaluation(decision: .allow, ruleMatched: nil, reason: nil)
    }

    /// The pattern string used to identify a matched rule (command regex, else path glob).
    static func patternOf(_ rule: Rule) -> String { rule.commandRegex ?? rule.pathGlob ?? "" }

    /// First rule in `rules` that matches the payload, or nil. Returns the whole `Rule` so callers
    /// can read tier metadata (e.g. `remoteOverridable`); `patternOf` recovers the display string.
    static func firstMatch(_ payload: HookPayload, command: String?, in rules: [Rule]) -> Rule? {
        for rule in rules {
            if let tool = rule.tool, tool != payload.toolName { continue }
            if let pattern = rule.commandRegex, let cmd = command,
               regexMatches(pattern, cmd) {
                return rule
            }
            if let glob = rule.pathGlob, let path = payload.toolInput?.filePath,
               fnmatch(glob, path, 0) == 0 {
                // NOTE: fnmatch does not honor "**"; the app compiles ** globs to explicit
                // patterns (or we swap to a glob→regex compile) in the permission-engine phase.
                return rule
            }
        }
        return nil
    }

    static func regexMatches(_ pattern: String, _ text: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return false }
        return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
