import XCTest
import CompanionCore
@testable import CompanionKit

final class RulesCompilerTests: XCTestCase {
    private func tmpDir() throws -> String {
        let dir = NSTemporaryDirectory() + "cc-rules-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    func testCompilesSmallYAML() throws {
        let yaml = """
        auto_accept: false
        deny:
          - { tool: Bash, command_regex: '\\brm\\s+-rf\\s+/' }
        ask:
          - { tool: Bash, command_regex: '\\bgit\\s+push\\b' }
          - { tool: Write, path_glob: '**/.env*' }
        """
        let r = try RulesCompiler.compile(yaml: yaml)
        XCTAssertFalse(r.compiled.autoAccept)
        XCTAssertEqual(r.compiled.deny.count, 1)
        XCTAssertEqual(r.compiled.ask.count, 2)
        XCTAssertTrue(r.warnings.isEmpty, "\(r.warnings)")
    }

    func testInvalidRegexDroppedWithWarning() throws {
        let yaml = """
        auto_accept: true
        deny:
          - { tool: Bash, command_regex: '[unclosed' }
        ask: []
        """
        let r = try RulesCompiler.compile(yaml: yaml)
        XCTAssertEqual(r.compiled.deny.count, 0)
        XCTAssertEqual(r.warnings.count, 1)
    }

    /// The gold test: the entire shipped default blacklist must compile with NO invalid regexes,
    /// and round-trip YAML → compiled JSON → decodable CompiledRules.
    func testBundledDefaultBlacklistCompilesCleanly() throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let mgr = RulesManager(rulesPath: dir + "/rules.yaml", compiledPath: dir + "/rules.compiled.json")

        mgr.ensureDefaultRules()
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir + "/rules.yaml"), "default not seeded")

        let warnings = try mgr.compile()
        XCTAssertEqual(warnings, [], "default blacklist has invalid regex(es): \(warnings)")

        let data = try Data(contentsOf: URL(fileURLWithPath: dir + "/rules.compiled.json"))
        let compiled = try JSONDecoder().decode(CompiledRules.self, from: data)
        XCTAssertTrue(compiled.autoAccept)
        XCTAssertGreaterThan(compiled.deny.count, 10)
        XCTAssertGreaterThan(compiled.ask.count, 10)

        // Sanity: a real catastrophic command is denied by the compiled default.
        let payload = HookPayload(hookEventName: "PreToolUse", toolName: "Bash",
                                  toolInput: ToolInput(command: "rm -rf /"))
        XCTAssertEqual(RuleEngine.evaluate(payload, rules: compiled).decision, .deny)
    }

    func testSetAutoAcceptFlipsAndPreservesFile() throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let mgr = RulesManager(rulesPath: dir + "/rules.yaml", compiledPath: dir + "/rules.compiled.json")
        mgr.ensureDefaultRules()
        XCTAssertTrue(mgr.currentAutoAccept())
        _ = try mgr.setAutoAccept(false)
        XCTAssertFalse(mgr.currentAutoAccept())
        // file still has the deny rules (not clobbered)
        let text = try String(contentsOfFile: dir + "/rules.yaml", encoding: .utf8)
        XCTAssertTrue(text.contains("no-preserve-root"), "rules body should survive the toggle")
    }
}
