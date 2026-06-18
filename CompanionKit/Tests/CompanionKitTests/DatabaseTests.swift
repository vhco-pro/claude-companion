import XCTest
import GRDB
import CompanionCore
@testable import CompanionKit

final class DatabaseTests: XCTestCase {
    private func tempDB() throws -> (AppDatabase, String) {
        let dir = NSTemporaryDirectory() + "cc-dbtest-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return (try AppDatabase(path: dir + "/companion.db"), dir)
    }

    func testMigrationCreatesSchemaV1() throws {
        let (db, dir) = try tempDB()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try db.dbQueue.read { db in
            for table in ["sessions", "tool_events", "token_usage", "audit", "pricing"] {
                XCTAssertTrue(try db.tableExists(table), "missing table \(table)")
            }
        }
    }

    func testMigrationIsIdempotent() throws {
        let dir = NSTemporaryDirectory() + "cc-dbtest-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        _ = try AppDatabase(path: dir + "/companion.db")
        XCTAssertNoThrow(try AppDatabase(path: dir + "/companion.db")) // re-open re-runs migrator
    }

    func testAuditInsertAndFetch() throws {
        let (db, dir) = try tempDB()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try db.dbQueue.write { db in
            var r = AuditRecord(id: nil, ts: "2026-06-15T00:00:00Z", sessionId: "s1",
                                promptId: nil, tool: "Bash", command: "rm -rf /",
                                decision: "deny", ruleMatched: "rx")
            try r.insert(db)
        }
        let rows = try db.dbQueue.read { try AuditRecord.fetchAll($0) }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.decision, "deny")
        XCTAssertNotNil(rows.first?.id) // autoincrement assigned
    }

    func testAuditIngestorResumesFromOffset() throws {
        let (db, dir) = try tempDB()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let auditPath = dir + "/audit.ndjson"
        let offsetPath = dir + "/audit.offset"

        // Write two complete lines + one partial (no trailing newline yet).
        let l1 = #"{"ts":"t1","sessionId":"s1","tool":"Bash","command":"rm -rf /","decision":"deny","ruleMatched":"rx"}"# + "\n"
        let l2 = #"{"ts":"t2","sessionId":"s1","tool":"Bash","command":"ls","decision":"allow","ruleMatched":null}"# + "\n"
        let partial = "{\"ts\":\"t3\",\"tool\":\"Bash\",\"" // incomplete prefix ending at a key boundary
        try (l1 + l2 + partial).write(toFile: auditPath, atomically: true, encoding: .utf8)

        let ingestor = AuditIngestor(db: db, auditPath: auditPath, offsetPath: offsetPath)
        XCTAssertEqual(try ingestor.ingestNew(), 2)               // two complete lines
        XCTAssertEqual(try ingestor.ingestNew(), 0)               // nothing new; partial not consumed

        // Complete the partial line so it forms valid JSON, + a trailing newline.
        let l3rest = #"command":"git push","decision":"ask","ruleMatched":"gp"}"# + "\n"
        let handle = FileHandle(forWritingAtPath: auditPath)!
        handle.seekToEndOfFile(); handle.write(Data((l3rest).utf8)); try handle.close()
        XCTAssertEqual(try ingestor.ingestNew(), 1)

        let count = try db.dbQueue.read { try AuditRecord.fetchCount($0) }
        XCTAssertEqual(count, 3)
    }
}
