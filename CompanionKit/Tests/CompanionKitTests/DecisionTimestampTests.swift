import XCTest
@testable import CompanionKit

/// Covers the ISO8601 parsing helpers that render "when a decision was surfaced" on the Needs
/// attention list (decision-timestamps.spec.md). Pure formatting - no DB/UI.
final class DecisionTimestampTests: XCTestCase {
    private func iso(secondsAgo: TimeInterval) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(-secondsAgo))
    }

    func testRelativeBuckets() {
        XCTAssertEqual(AppModel.relative(iso: iso(secondsAgo: 5)), "just now")
        XCTAssertEqual(AppModel.relative(iso: iso(secondsAgo: 120)), "2m ago")
        XCTAssertEqual(AppModel.relative(iso: iso(secondsAgo: 7200)), "2h ago")
        XCTAssertEqual(AppModel.relative(iso: iso(secondsAgo: 3 * 86400)), "3d ago")
    }

    func testParsesPlainAndFractionalSeconds() {
        // The hook writes the plain `…Z` form today; tolerate fractional seconds too.
        XCTAssertNotNil(AppModel.relative(iso: "2026-07-09T01:33:46Z"))
        XCTAssertNotNil(AppModel.relative(iso: "2026-07-09T01:33:46.123Z"))
        XCTAssertNotNil(AppModel.absolute(iso: "2026-07-09T01:33:46Z"))
    }

    func testUnparseableAndNilYieldNil() {
        XCTAssertNil(AppModel.relative(iso: "not-a-date"))
        XCTAssertNil(AppModel.relative(iso: ""))
        XCTAssertNil(AppModel.relative(iso: nil))
        XCTAssertNil(AppModel.absolute(iso: "not-a-date"))
        XCTAssertNil(AppModel.absolute(iso: nil))
    }
}
