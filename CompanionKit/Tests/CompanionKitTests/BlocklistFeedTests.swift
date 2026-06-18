import XCTest
import CompanionCore
@testable import CompanionKit

final class BlocklistFeedTests: XCTestCase {
    func testParseHostsFormat() {
        let text = """
        # comment
        0.0.0.0 evil.com
        127.0.0.1 bad.org
        localhost
        0.0.0.0 0.0.0.0
        """
        XCTAssertEqual(FeedParser.parse(text, format: "hosts"), ["evil.com", "bad.org"])
    }

    func testParseDomainsFormat() {
        let text = "evil.com\n# note\n\nBad.ORG\n"
        XCTAssertEqual(FeedParser.parse(text, format: "domains"), ["evil.com", "bad.org"])
    }

    func testParseUrlsFormat() {
        let text = "https://evil.com/install.sh\nhttp://bad.org/x?y=1\n"
        XCTAssertEqual(FeedParser.parse(text, format: "urls"), ["evil.com", "bad.org"])
    }

    func testCompileSortsExcludesOverridesAndPrefersMalicious() throws {
        let dir = NSTemporaryDirectory() + "cc-blc-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let out = dir + "/blocklist.db"

        let entries: [(host: String, cls: DomainClass)] = [
            ("zebra.com", .compromised),
            ("apple.com", .malicious),
            ("apple.com", .compromised),   // malicious must win
            ("override.me", .malicious),   // excluded
        ]
        let count = try BlocklistCompiler.compile(entries: entries, overrides: ["override.me"], outPath: out)
        XCTAssertEqual(count, 2)

        let body = try String(contentsOfFile: out, encoding: .utf8)
        XCTAssertEqual(body, "apple.com\tmalicious\nzebra.com\tcompromised\n") // sorted, override gone, malicious won

        // round-trips through Blocklist.load
        let bl = try XCTUnwrap(Blocklist.load(path: out))
        XCTAssertEqual(bl.lookup("apple.com"), .malicious)
        XCTAssertNil(bl.lookup("override.me"))
    }
}
