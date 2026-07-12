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

    func testDecodesCurrentLiveShape2026_07() throws {
        // Full live payload captured 2026-07-12: the API grew `limits`, `spend`, `extra_usage`, and
        // a raft of null codename buckets. Guards the recurring "shape drifted → we silently keep
        // last-good" regression - the two buckets we render must still parse.
        let json = #"""
        {"five_hour":{"utilization":4.0,"resets_at":"2026-07-12T07:59:59.731334+00:00","limit_dollars":null,"used_dollars":null},
         "seven_day":{"utilization":31.0,"resets_at":"2026-07-16T21:59:59.731362+00:00","limit_dollars":null},
         "seven_day_oauth_apps":null,"seven_day_opus":null,"seven_day_sonnet":null,"seven_day_cowork":null,
         "tangelo":null,"iguana_necktie":null,"nimbus_quill":null,
         "extra_usage":{"is_enabled":false,"monthly_limit":0,"currency":"EUR"},
         "limits":[{"kind":"weekly_all","group":"weekly","percent":31,"severity":"normal","is_active":true}],
         "spend":{"percent":0,"enabled":false},"member_dashboard_available":false}
        """#
        let s = try JSONDecoder().decode(UsageSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(s.fiveHour?.utilization, 4.0)
        XCTAssertEqual(s.fiveHour?.resetsAt, "2026-07-12T07:59:59.731334+00:00")
        XCTAssertEqual(s.sevenDay?.utilization, 31.0)
        XCTAssertNil(s.sevenDayOpus)                       // null → nil, unchanged
    }

    func testDecodesEmptyAndPartial() throws {
        XCTAssertNoThrow(try JSONDecoder().decode(UsageSnapshot.self, from: Data("{}".utf8)))
        let partial = try JSONDecoder().decode(UsageSnapshot.self, from: Data(#"{"five_hour":{"utilization":5.0}}"#.utf8))
        XCTAssertEqual(partial.fiveHour?.utilization, 5.0)
        XCTAssertNil(partial.fiveHour?.resetsAt)           // missing field tolerated
        XCTAssertNil(partial.sevenDay)
    }
}
