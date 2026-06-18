import XCTest
@testable import CompanionCore

final class RuleEngineTests: XCTestCase {
    private func bash(_ command: String) -> HookPayload {
        HookPayload(hookEventName: "PreToolUse", toolName: "Bash",
                    toolInput: ToolInput(command: command))
    }

    private let rules = CompiledRules(
        autoAccept: true,
        deny: [Rule(tool: "Bash", commandRegex: #"\brm\s+-rf\s+(/|~|\$HOME)"#)],
        ask:  [Rule(tool: "Bash", commandRegex: #"\bgit\s+push\b"#)]
    )

    func testNonMatchingCommandAllows() {
        XCTAssertEqual(RuleEngine.evaluate(bash("ls -la"), rules: rules).decision, .allow)
    }

    func testDenyRuleBlocks() {
        let e = RuleEngine.evaluate(bash("rm -rf /"), rules: rules)
        XCTAssertEqual(e.decision, .deny)
        XCTAssertNotNil(e.ruleMatched)
    }

    func testAskRulePrompts() {
        XCTAssertEqual(RuleEngine.evaluate(bash("git push origin main"), rules: rules).decision, .ask)
    }

    func testAutoAcceptOffAlwaysAsks() {
        let off = CompiledRules(autoAccept: false, deny: rules.deny, ask: rules.ask)
        XCTAssertEqual(RuleEngine.evaluate(bash("ls -la"), rules: off).decision, .ask)
    }

    func testDecisionOutputShapeMatchesClaudeCodeContract() throws {
        let json = try JSONEncoder().encode(HookDecisionOutput(.deny, reason: "x"))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        let inner = try XCTUnwrap(obj["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(inner["hookEventName"] as? String, "PreToolUse")
        XCTAssertEqual(inner["permissionDecision"] as? String, "deny")
    }

    func testHookPayloadDecodesConfirmedSchema() throws {
        let payloadJSON = #"""
        {"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/p","permission_mode":"default",
         "tool_name":"Bash","tool_input":{"command":"echo hi","description":"d"}}
        """#
        let p = try JSONDecoder().decode(HookPayload.self, from: Data(payloadJSON.utf8))
        XCTAssertEqual(p.toolName, "Bash")
        XCTAssertEqual(p.toolInput?.command, "echo hi")
        XCTAssertEqual(p.cwd, "/p")
    }
}
