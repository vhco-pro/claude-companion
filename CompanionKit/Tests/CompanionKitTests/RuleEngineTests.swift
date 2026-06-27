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

    // MARK: - Allow tier (allow-tier.spec.md)

    /// allow exception sits after deny+malicious, before ask → it clears an `ask` match.
    func testAllowExceptionClearsAskMatch() {
        let r = CompiledRules(autoAccept: true, deny: rules.deny, ask: rules.ask,
                              allow: [Rule(tool: "Bash", commandRegex: #"\bgit\s+push\b"#)])
        let e = RuleEngine.evaluate(bash("git push origin main"), rules: r)
        XCTAssertEqual(e.decision, .allow)
        XCTAssertEqual(e.ruleMatched, #"\bgit\s+push\b"#)
    }

    /// allow can NEVER override a hard deny — deny is evaluated first and short-circuits.
    func testAllowExceptionCannotOverrideHardDeny() {
        let r = CompiledRules(autoAccept: true, deny: rules.deny, ask: rules.ask,
                              allow: [Rule(tool: "Bash", commandRegex: #"\brm\s+-rf\s+/"#)])
        XCTAssertEqual(RuleEngine.evaluate(bash("rm -rf /"), rules: r).decision, .deny)
    }

    /// allow clears a compromised-domain match (which is otherwise `ask`).
    func testAllowExceptionClearsCompromisedURLMatch() {
        let bl = Blocklist(entries: ["evil.example": .compromised])
        let r = CompiledRules(autoAccept: true, deny: [], ask: [],
                              allow: [Rule(tool: "Bash", commandRegex: #"curl"#)])
        let e = RuleEngine.evaluate(bash("curl https://evil.example/x"), rules: r, blocklist: bl)
        XCTAssertEqual(e.decision, .allow)
    }

    /// allow can NEVER override a malicious-URL block (deny tier, evaluated before allow).
    func testAllowExceptionCannotOverrideMaliciousURL() {
        let bl = Blocklist(entries: ["bad.example": .malicious])
        let r = CompiledRules(autoAccept: true, deny: [], ask: [],
                              allow: [Rule(tool: "Bash", commandRegex: #"curl"#)])
        let e = RuleEngine.evaluate(bash("curl https://bad.example/x"), rules: r, blocklist: bl)
        XCTAssertEqual(e.decision, .deny)
    }

    /// A pre-allow-tier rules.compiled.json (no `allow` key) still decodes (allow defaults to []).
    func testCompiledRulesDecodesWithoutAllowKey() throws {
        let legacy = #"{"auto_accept":true,"deny":[],"ask":[]}"#
        let c = try JSONDecoder().decode(CompiledRules.self, from: Data(legacy.utf8))
        XCTAssertTrue(c.allow.isEmpty)
        XCTAssertTrue(c.autoAccept)
    }

    /// The deny reason (the only signal the model gets) tells it not to work around the block.
    func testDenyReasonGuidesTheModel() {
        let e = RuleEngine.evaluate(bash("rm -rf /"), rules: rules)
        XCTAssertEqual(e.decision, .deny)
        let reason = e.reason ?? ""
        XCTAssertTrue(reason.contains("Claude Companion"), reason)
        XCTAssertTrue(reason.lowercased().contains("ask the user"), reason)
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
