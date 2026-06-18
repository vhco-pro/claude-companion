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

    public static func compile(yaml: String) throws -> Result {
        let file = try YAMLDecoder().decode(RulesFile.self, from: yaml)
        var warnings: [String] = []

        func convert(_ specs: [RuleSpec], tier: String) -> [Rule] {
            specs.compactMap { spec in
                if let rx = spec.commandRegex, (try? NSRegularExpression(pattern: rx)) == nil {
                    warnings.append("\(tier): invalid regex skipped - \(rx)")
                    return nil
                }
                return Rule(tool: spec.tool, commandRegex: spec.commandRegex, pathGlob: spec.pathGlob)
            }
        }

        let compiled = CompiledRules(
            autoAccept: file.autoAccept,
            deny: convert(file.deny, tier: "deny"),
            ask: convert(file.ask, tier: "ask")
        )
        return Result(compiled: compiled, warnings: warnings)
    }

    /// Compile `yamlPath` → `outPath` (atomic write). Returns warnings ([] = clean).
    @discardableResult
    public static func compileFile(yamlPath: String, outPath: String) throws -> [String] {
        let yaml = try String(contentsOfFile: yamlPath, encoding: .utf8)
        let result = try compile(yaml: yaml)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(result.compiled).write(to: URL(fileURLWithPath: outPath), options: .atomic)
        return result.warnings
    }
}
