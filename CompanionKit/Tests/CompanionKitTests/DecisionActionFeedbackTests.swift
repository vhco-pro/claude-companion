import XCTest
@testable import CompanionKit

/// Covers the pure summary helper that labels a just-actioned decision in the confirmation toast /
/// row mark (decision-action-feedback.spec.md). Pure formatting - no DB/UI/rules.
final class DecisionActionFeedbackTests: XCTestCase {
    private func record(tool: String? = "Bash", command: String?) -> AuditRecord {
        AuditRecord(id: 1, ts: "2026-07-10T00:00:00Z", sessionId: nil, promptId: nil,
                    tool: tool, command: command, decision: "ask", ruleMatched: nil)
    }

    func testOneLinesMultiWhitespaceCommand() {
        let r = record(command: "git   push\n  origin\tmain")
        XCTAssertEqual(AppModel.actionSummary(r), "git push origin main")
    }

    func testTruncatesOverLongCommand() {
        let long = String(repeating: "a", count: 100)
        let s = AppModel.actionSummary(record(command: long))
        XCTAssertEqual(s.count, 61)          // 60 chars + the ellipsis
        XCTAssertTrue(s.hasSuffix("…"))
    }

    func testFallsBackToToolWhenCommandAbsent() {
        XCTAssertEqual(AppModel.actionSummary(record(command: nil)), "Bash")
        XCTAssertEqual(AppModel.actionSummary(record(command: "")), "Bash")
        XCTAssertEqual(AppModel.actionSummary(record(command: "   ")), "Bash")
    }

    func testDashWhenBothAbsent() {
        XCTAssertEqual(AppModel.actionSummary(record(tool: nil, command: nil)), "—")
        XCTAssertEqual(AppModel.actionSummary(record(tool: "", command: "")), "—")
    }
}
