import XCTest
import CompanionCore
@testable import CompanionKit

final class PricingTests: XCTestCase {
    private let table = PricingTable(table: [
        "claude-opus-4-8": ModelPricing(input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75),
    ])

    func testCostComputation() {
        // 1M of each kind → sum of the per-Mtok rates.
        let c = table.cost(model: "claude-opus-4-8", input: 1_000_000, output: 1_000_000,
                           cacheRead: 1_000_000, cacheWrite: 1_000_000)
        XCTAssertEqual(try XCTUnwrap(c), 15 + 75 + 1.5 + 18.75, accuracy: 0.0001)
    }

    func testUnknownModelAndNilAreNil() {
        XCTAssertNil(table.cost(model: "claude-mystery-9", input: 1000, output: 1000, cacheRead: 0, cacheWrite: 0))
        XCTAssertNil(table.cost(model: nil, input: 1000, output: 0, cacheRead: 0, cacheWrite: 0))
    }

    func testSuffixVariantMatches() {
        XCTAssertNotNil(table.pricing(for: "claude-opus-4-8[1m]"))  // base-id prefix match
    }

    func testBundledDefaultSeedsAndLoads() throws {
        let dir = NSTemporaryDirectory() + "cc-price-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = PricingStore(path: dir + "/pricing.yaml")
        store.ensureDefault()
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir + "/pricing.yaml"))
        let t = store.load()
        XCTAssertNotNil(t.pricing(for: "claude-opus-4-8"))
        XCTAssertNotNil(t.pricing(for: "claude-fable-5"))
    }

    func testSummaryIncludesCost() throws {
        let dbDir = NSTemporaryDirectory() + "cc-pc-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dbDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dbDir) }
        let db = try AppDatabase(path: dbDir + "/companion.db")
        let ing = SessionIngestor(db: db)
        let line = #"""
        {"type":"assistant","sessionId":"s1","cwd":"/x/proj","message":{"model":"claude-opus-4-8","usage":{"input_tokens":1000000,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"content":[]}}
        """#
        ing.ingest(JSONLParser.parse(line)!)
        let s = ing.summaries(pricing: table)[0]
        XCTAssertEqual(try XCTUnwrap(s.costUSD), 15.0, accuracy: 0.0001) // 1M input × $15/Mtok
    }
}
