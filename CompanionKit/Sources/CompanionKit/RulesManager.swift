import CompanionCore
import Foundation
import Yams

/// Owns the rules.yaml → rules.compiled.json lifecycle: seed the bundled default on first run,
/// recompile on demand (the app calls this on launch + whenever rules.yaml changes), and the
/// kill-switch toggle. The hook only ever reads the compiled JSON.
public final class RulesManager {
    public let rulesPath: String
    public let localPath: String
    public let compiledPath: String

    public init(rulesPath: String = Paths.rulesFile,
                localPath: String = Paths.rulesLocalFile,
                compiledPath: String = Paths.rulesCompiled) {
        self.rulesPath = rulesPath
        self.localPath = localPath
        self.compiledPath = compiledPath
    }

    /// Write the bundled default rules.yaml if the user has none yet.
    public func ensureDefaultRules() {
        guard !FileManager.default.fileExists(atPath: rulesPath) else { return }
        guard let url = Bundle.module.url(forResource: "default-rules", withExtension: "yaml"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let dir = (rulesPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? text.write(toFile: rulesPath, atomically: true, encoding: .utf8)
    }

    /// Compile rules.yaml (+ rules.local.yaml overrides) → rules.compiled.json. Warnings ([] = clean).
    @discardableResult
    public func compile() throws -> [String] {
        try RulesCompiler.compileFile(yamlPath: rulesPath, localPath: localPath, outPath: compiledPath)
    }

    // MARK: - Local overrides (allow-tier.spec.md). The app only ever writes rules.local.yaml.

    /// Load the app-owned local overrides, or an empty set if the file is absent/unreadable.
    public func loadLocal() -> LocalRulesFile {
        guard let yaml = try? String(contentsOfFile: localPath, encoding: .utf8),
              let local = try? YAMLDecoder().decode(LocalRulesFile.self, from: yaml)
        else { return LocalRulesFile() }
        return local
    }

    /// Persist the local overrides (struct → YAML, atomic) and recompile. Never touches rules.yaml.
    /// Returns compile warnings ([] = clean).
    @discardableResult
    public func saveLocal(_ local: LocalRulesFile) throws -> [String] {
        let yaml = try YAMLEncoder().encode(local)
        let dir = (localPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try yaml.write(toFile: localPath, atomically: true, encoding: .utf8)
        return try compile()
    }

    /// "Always allow this": add a scoped allow exception (tool + matched pattern) and recompile.
    /// De-dupes on identity so repeated clicks don't pile up. Returns compile warnings.
    @discardableResult
    public func addAllowException(tool: String?, commandRegex: String?, pathGlob: String? = nil) throws -> [String] {
        var local = loadLocal()
        let spec = RuleSpec(tool: tool, commandRegex: commandRegex, pathGlob: pathGlob)
        guard !local.allow.contains(where: { $0.identity == spec.identity }) else { return [] }
        local.allow.append(spec)
        return try saveLocal(local)
    }

    /// "Block this": add a user deny rule and recompile. Returns compile warnings.
    @discardableResult
    public func addDeny(tool: String?, commandRegex: String?, pathGlob: String? = nil) throws -> [String] {
        var local = loadLocal()
        let spec = RuleSpec(tool: tool, commandRegex: commandRegex, pathGlob: pathGlob)
        guard !local.deny.contains(where: { $0.identity == spec.identity }) else { return [] }
        local.deny.append(spec)
        return try saveLocal(local)
    }

    /// Scope an exception derived from a recorded decision to the matched tool + pattern (the
    /// spec's default granularity):
    /// - a command-regex match → reuse that regex (ruleMatched IS the pattern);
    /// - a blocklist match `blocklist:<host>` (compromised/malicious) → an escaped-host regex;
    /// - no specific rule (e.g. auto-accept-off) → the exact command, escaped.
    public static func exceptionScope(tool: String?, command: String?,
                                      ruleMatched: String?) -> (tool: String?, pattern: String) {
        if let rm = ruleMatched, rm.hasPrefix("blocklist:") {
            let host = String(rm.dropFirst("blocklist:".count))
            return (tool, NSRegularExpression.escapedPattern(for: host))
        }
        if let rm = ruleMatched, !rm.isEmpty {
            return (tool, rm)
        }
        return (tool, NSRegularExpression.escapedPattern(for: command ?? ""))
    }

    /// Toggle a shipped rule off/on by its identity (`tool|pattern`) and recompile. Disabling a
    /// base ask rule stops it matching; a base hard deny is never removed by this (see compiler).
    @discardableResult
    public func setRuleDisabled(identity: String, disabled: Bool) throws -> [String] {
        var local = loadLocal()
        if disabled {
            guard !local.disabled.contains(identity) else { return [] }
            local.disabled.append(identity)
        } else {
            local.disabled.removeAll { $0 == identity }
        }
        return try saveLocal(local)
    }

    public func currentAutoAccept() -> Bool {
        guard let yaml = try? String(contentsOfFile: rulesPath, encoding: .utf8),
              let result = try? RulesCompiler.compile(yaml: yaml) else { return true }
        return result.compiled.autoAccept
    }

    /// Kill switch: flip `auto_accept` in rules.yaml (minimal text edit preserving the rest of
    /// the file) and recompile. Returns the new value.
    @discardableResult
    public func setAutoAccept(_ value: Bool) throws -> Bool {
        var text = (try? String(contentsOfFile: rulesPath, encoding: .utf8)) ?? "auto_accept: \(value)\n"
        let pattern = #"(?m)^\s*auto_accept\s*:\s*(true|false)\s*$"#
        let replacement = "auto_accept: \(value)"
        if let re = try? NSRegularExpression(pattern: pattern),
           re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
            text = re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
        } else {
            text = "auto_accept: \(value)\n" + text   // no existing key - prepend
        }
        try text.write(toFile: rulesPath, atomically: true, encoding: .utf8)
        try compile()
        return value
    }
}
