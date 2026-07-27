import CompanionCore
import Foundation
import Yams

/// Compiles the human-edited rules.yaml into rules.compiled.json (the JSON the hook reads).
/// Validates each regex compiles - invalid ones are dropped with a warning rather than poisoning
/// the whole file.
public enum RulesCompiler {
    public struct Result: Sendable {
        public let compiled: CompiledRules
        public let warnings: [String]
    }

    /// Base-only compile (no local overrides). Equivalent to merging with an empty local file.
    public static func compile(yaml: String) throws -> Result {
        try compileMerged(baseYAML: yaml, localYAML: nil)
    }

    /// The allow tier is purely permissive (it can never weaken a deny), so the SHIPPED allow
    /// defaults are always applied - even for an existing user whose copied-once `rules.yaml`
    /// predates them. `shippedAllow` carries the bundled default's allow specs; they're merged with
    /// (and de-duped against) the user's own allow + local allow. See remote-ssh follow-up.

    /// Merge the shipped `rules.yaml` with the app-owned `rules.local.yaml` into one CompiledRules
    /// (see allow-tier.spec.md). Precedence:
    /// - local `allow` exceptions populate the engine's allow tier (clears ask/compromised, never deny);
    /// - local `deny`/`ask` are appended to their base tiers;
    /// - local `disabled` turns off matching base **ask** rules only - a base hard `deny` is never
    ///   removed by the local file (you can't silently disable a deny).
    public static func compileMerged(baseYAML: String, localYAML: String?,
                                     shippedAllow: [RuleSpec] = []) throws -> Result {
        let base = try YAMLDecoder().decode(RulesFile.self, from: baseYAML)
        let local: LocalRulesFile = (localYAML.flatMap { try? YAMLDecoder().decode(LocalRulesFile.self, from: $0) }) ?? LocalRulesFile()
        var warnings: [String] = []

        // Allow tier = user's allow + the shipped defaults + local exceptions, de-duped by identity
        // (a current user whose rules.yaml already carries the defaults won't double them).
        var seenAllow = Set<String>()
        let mergedAllow = (base.allow + shippedAllow + local.allow).filter { seenAllow.insert($0.identity).inserted }

        func convert(_ specs: [RuleSpec], tier: String) -> [Rule] {
            specs.compactMap { spec in
                if let rx = spec.commandRegex, (try? NSRegularExpression(pattern: rx)) == nil {
                    warnings.append("\(tier): invalid regex skipped - \(rx)")
                    return nil
                }
                return Rule(tool: spec.tool, commandRegex: spec.commandRegex, pathGlob: spec.pathGlob,
                            remoteOverridable: spec.remoteOverridable)
            }
        }

        // `disabled` turns off matching base ASK and CONFIRM rules (both are human-prompt tiers); a
        // base hard `deny` is never removed by the local file (see docstring).
        let disabledSet = Set(local.disabled)
        let baseAsk = base.ask.filter { !disabledSet.contains($0.identity) }
        let baseConfirm = base.confirm.filter { !disabledSet.contains($0.identity) }

        let compiled = CompiledRules(
            autoAccept: base.autoAccept,
            deny: convert(base.deny, tier: "deny") + convert(local.deny, tier: "local deny"),
            ask: convert(baseAsk, tier: "ask") + convert(local.ask, tier: "local ask"),
            allow: convert(mergedAllow, tier: "allow"),
            confirm: convert(baseConfirm, tier: "confirm") + convert(local.confirm, tier: "local confirm")
        )
        return Result(compiled: compiled, warnings: warnings)
    }

    /// Compile `yamlPath` (+ optional `localPath`) → `outPath` (atomic write). Returns warnings.
    @discardableResult
    public static func compileFile(yamlPath: String, localPath: String? = nil, outPath: String,
                                   shippedAllow: [RuleSpec] = []) throws -> [String] {
        let yaml = try String(contentsOfFile: yamlPath, encoding: .utf8)
        let localYAML = localPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        let result = try compileMerged(baseYAML: yaml, localYAML: localYAML, shippedAllow: shippedAllow)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(result.compiled).write(to: URL(fileURLWithPath: outPath), options: .atomic)
        return result.warnings
    }
}
