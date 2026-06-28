import XCTest
import GRDB
import CompanionCore
@testable import CompanionKit

/// P1 of remote-ssh: every per-session / per-decision row gains a `host` dimension. Local data is
/// "local" (no behaviour change); remote rows carry the SSH alias and namespace their session ids.
final class RemoteHostDimensionTests: XCTestCase {
    private func tempDB() throws -> (AppDatabase, String) {
        let dir = NSTemporaryDirectory() + "cc-host-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return (try AppDatabase(path: dir + "/companion.db"), dir)
    }

    /// The v2 migration adds `host` to all four tables, and the `NOT NULL DEFAULT 'local'` makes a
    /// row inserted without a host fall to "local" - the same mechanism that backfills legacy rows.
    func testHostColumnDefaultsToLocal() throws {
        let (db, dir) = try tempDB(); defer { try? FileManager.default.removeItem(atPath: dir) }
        try db.dbQueue.read { db in
            for table in ["sessions", "tool_events", "token_usage", "audit"] {
                let cols = try db.columns(in: table).map(\.name)
                XCTAssertTrue(cols.contains("host"), "\(table) missing host column")
            }
        }
        // Insert omitting host on each table → reads back 'local'.
        try db.dbQueue.write { db in
            try db.execute(sql: "INSERT INTO sessions (id) VALUES ('legacy')")
            try db.execute(sql: "INSERT INTO audit (ts, decision) VALUES ('t', 'deny')")
        }
        try db.dbQueue.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT host FROM sessions WHERE id='legacy'"), "local")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT host FROM audit LIMIT 1"), "local")
        }
    }

    func testNamespacedIdHelper() {
        XCTAssertEqual(SessionIngestor.namespacedId(host: "local", sessionId: "s1"), "s1")
        XCTAssertEqual(SessionIngestor.namespacedId(host: "fedora", sessionId: "s1"), "fedora:s1")
    }

    private let line = #"{"type":"assistant","sessionId":"s1","cwd":"/home/m/proj","timestamp":"2026-06-15T10:00:00Z","message":{"model":"claude-opus-4-8","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}"#

    func testLocalIngestTagsLocalWithBareId() throws {
        let (db, dir) = try tempDB(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let ing = SessionIngestor(db: db)
        ing.ingest(JSONLParser.parse(line)!)              // default host = local
        let s = ing.summaries()[0]
        XCTAssertEqual(s.id, "s1")                         // bare, no namespace
        XCTAssertEqual(s.host, "local")
    }

    func testRemoteIngestNamespacesAndTagsHost() throws {
        let (db, dir) = try tempDB(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let ing = SessionIngestor(db: db)
        let e = JSONLParser.parse(line)!
        ing.ingest(e, host: "fedora")
        ing.ingest(e, host: "build-box")                  // SAME raw id "s1" on a different host
        let summaries = ing.summaries()
        // Two hosts with the same raw session id must NOT merge into one row.
        XCTAssertEqual(summaries.count, 2)
        XCTAssertEqual(Set(summaries.map(\.id)), ["fedora:s1", "build-box:s1"])
        XCTAssertEqual(Set(summaries.map(\.host)), ["fedora", "build-box"])
    }

    func testAuditIngestTagsHostAndNamespacesSession() throws {
        let (db, dir) = try tempDB(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let auditPath = dir + "/audit.ndjson", offsetPath = dir + "/audit.offset"
        let l = #"{"ts":"t1","sessionId":"s1","tool":"Bash","command":"rm -rf /","decision":"deny","ruleMatched":"rx"}"# + "\n"
        try l.write(toFile: auditPath, atomically: true, encoding: .utf8)

        let ing = AuditIngestor(db: db, auditPath: auditPath, offsetPath: offsetPath)
        XCTAssertEqual(try ing.ingestNew(host: "fedora"), 1)
        let rec = try db.dbQueue.read { try AuditRecord.fetchAll($0) }.first
        XCTAssertEqual(rec?.host, "fedora")
        XCTAssertEqual(rec?.sessionId, "fedora:s1")        // joins to the remote session row
    }
}
