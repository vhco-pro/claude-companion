import CompanionCore
import Foundation
import GRDB

/// Tails `audit.ndjson` (written by the hook) and ingests new lines into the `audit` table.
/// Resumes from a persisted byte offset so a restart doesn't re-ingest. Partial trailing lines
/// (a hook mid-write) are left for the next pass.
public final class AuditIngestor {
    private let db: AppDatabase
    private let auditPath: String
    private let offsetPath: String

    public init(db: AppDatabase, auditPath: String = Paths.auditLog, offsetPath: String = Paths.auditOffset) {
        self.db = db
        self.auditPath = auditPath
        self.offsetPath = offsetPath
    }

    private func loadOffset() -> UInt64 {
        guard let s = try? String(contentsOfFile: offsetPath, encoding: .utf8),
              let v = UInt64(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return 0 }
        return v
    }

    private func saveOffset(_ v: UInt64) {
        try? String(v).write(toFile: offsetPath, atomically: true, encoding: .utf8)
    }

    /// Ingest any complete new lines. Returns the number of rows inserted. `host` tags every row
    /// ("local" for the Mac's own audit; an SSH alias for a remote's pulled audit).
    @discardableResult
    public func ingestNew(host: String = "local") throws -> Int {
        guard let fh = FileHandle(forReadingAtPath: auditPath) else { return 0 }
        defer { try? fh.close() }

        let offset = loadOffset()
        try fh.seek(toOffset: offset)
        let data = fh.readDataToEndOfFile()
        guard !data.isEmpty else { return 0 }

        let bytes = [UInt8](data)
        guard let lastNL = bytes.lastIndex(of: 0x0A) else { return 0 } // no complete line yet
        let consumable = Data(bytes[0...lastNL])
        let lines = consumable.split(separator: 0x0A, omittingEmptySubsequences: true)

        var count = 0
        try db.dbQueue.write { db in
            for line in lines {
                guard let entry = try? JSONDecoder().decode(AuditEntry.self, from: Data(line)) else { continue }
                // Namespace the session id the same way SessionIngestor does, so a remote audit row
                // joins to its remote session (and local stays bare).
                let sid = entry.sessionId.map { SessionIngestor.namespacedId(host: host, sessionId: $0) }
                var rec = AuditRecord(
                    id: nil, ts: entry.ts, sessionId: sid, promptId: nil,
                    tool: entry.tool, command: entry.command,
                    decision: entry.decision, ruleMatched: entry.ruleMatched, host: host
                )
                try rec.insert(db)
                count += 1
            }
        }

        saveOffset(offset + UInt64(lastNL + 1))
        return count
    }
}
