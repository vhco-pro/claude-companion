import XCTest
@testable import CompanionKit

final class UsageTests: XCTestCase {
    func testDecodesConfirmedShapeWithNulls() throws {
        // Exact shape from the live probe, including null per-model buckets + extra keys.
        let json = #"""
        {"five_hour":{"utilization":22.0,"resets_at":"2026-06-15T20:00:00Z"},
         "seven_day":{"utilization":23.0,"resets_at":"2026-06-18T22:00:00Z"},
         "seven_day_opus":null,
         "seven_day_sonnet":{"utilization":0.0,"resets_at":"2026-06-18T22:00:00Z"},
         "extra_usage":{"is_enabled":false}}
        """#
        let s = try JSONDecoder().decode(UsageSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(s.fiveHour?.utilization, 22.0)
        XCTAssertEqual(s.fiveHour?.resetsAt, "2026-06-15T20:00:00Z")
        XCTAssertEqual(s.sevenDay?.utilization, 23.0)
        XCTAssertNil(s.sevenDayOpus)                       // null → nil
        XCTAssertEqual(s.sevenDaySonnet?.utilization, 0.0)
    }

    func testDecodesEmptyAndPartial() throws {
        XCTAssertNoThrow(try JSONDecoder().decode(UsageSnapshot.self, from: Data("{}".utf8)))
        let partial = try JSONDecoder().decode(UsageSnapshot.self, from: Data(#"{"five_hour":{"utilization":5.0}}"#.utf8))
        XCTAssertEqual(partial.fiveHour?.utilization, 5.0)
        XCTAssertNil(partial.fiveHour?.resetsAt)           // missing field tolerated
        XCTAssertNil(partial.sevenDay)
    }
}
