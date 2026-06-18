import CompanionCore
import Foundation

/// Owns the rules.yaml → rules.compiled.json lifecycle: seed the bundled default on first run,
/// recompile on demand (the app calls this on launch + whenever rules.yaml changes), and the
/// kill-switch toggle. The hook only ever reads the compiled JSON.
public final class RulesManager {
    public let rulesPath: String
    public let compiledPath: String

    public init(rulesPath: String = Paths.rulesFile, compiledPath: String = Paths.rulesCompiled) {
        self.rulesPath = rulesPath
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

    /// Compile rules.yaml → rules.compiled.json. Returns warnings ([] = clean).
    @discardableResult
    public func compile() throws -> [String] {
        try RulesCompiler.compileFile(yamlPath: rulesPath, outPath: compiledPath)
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
