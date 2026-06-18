import CompanionCore
import Foundation
import GRDB

/// Read-only summary of a session for the menu UI.
public struct SessionSummary: Identifiable, Sendable, Equatable {
    public let id: String
    public let projectName: String
    public let model: String?
    public let toolCount: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheTokens: Int
    public let costUSD: Double?        // nil if the model isn't priced
    public let projectPath: String?    // full cwd (the card shows only the leaf name)
    public let startedAt: Date?
    public let lastSeen: Date?
    public let active: Bool
    public let recentTools: [String]   // newest-first
    public let repoURL: URL?           // web URL of the cwd's git repo, if any (resolved + cached)
}

/// Turns parsed JSONL events into rows in the app DB and answers session summaries.
public final class SessionIngestor {
    private let db: AppDatabase
    /// A session counts as "active" if seen within this window.
    public var activeWindow: TimeInterval = 30 * 60

    public init(db: AppDatabase) { self.db = db }

    /// Friendly project label from a cwd. Home dir → "~" (not the username); else the dir name.
    static func friendlyProject(_ path: String?) -> String {
        guard let p = path else { return "—" }
        if p == NSHomeDirectory() { return "~" }
        return (p as NSString).lastPathComponent
    }

    public func ingest(_ e: ParsedEvent, now: Date = Date()) {
        try? db.dbQueue.write { db in try Self.write(db, e, now) }
    }

    /// Ingest many events (one file's worth) in a SINGLE transaction - far faster than a
    /// transaction per event on the first full scan.
    public func ingestBatch(_ items: [(event: ParsedEvent, at: Date)]) {
        guard !items.isEmpty else { return }
        try? db.dbQueue.write { db in
            for item in items { try Self.write(db, item.event, item.at) }
        }
    }

    private static func write(_ db: Database, _ e: ParsedEvent, _ now: Date) throws {
        guard let sid = e.sessionId else { return }
        try db.execute(sql: """
            INSERT INTO sessions (id, project_path, model, started_at, last_seen_at, status)
            VALUES (?, ?, ?, ?, ?, 'active')
            ON CONFLICT(id) DO UPDATE SET
              last_seen_at = excluded.last_seen_at,
              model = COALESCE(excluded.model, sessions.model),
              project_path = COALESCE(excluded.project_path, sessions.project_path),
              status = 'active'
            """, arguments: [sid, e.cwd, e.model, now, now])

        if let u = e.usage {
            try db.execute(sql: """
                INSERT INTO token_usage (session_id, ts, input, output, cache_read, cache_write)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [sid, now, u.input, u.output, u.cacheRead, u.cacheWrite])
        }
        for t in e.toolUses {
            try db.execute(sql: """
                INSERT INTO tool_events (session_id, ts, tool, bash_command, target_path)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [sid, now, t.name, t.command, t.filePath])
        }
    }

    /// Per-tool call counts for one session (e.g. Bash ×412, Edit ×98) - not shown on the card.
    public func toolBreakdown(_ sessionId: String, limit: Int = 8) -> [(tool: String, count: Int)] {
        (try? db.dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT tool, COUNT(*) AS c FROM tool_events WHERE session_id = ?
                GROUP BY tool ORDER BY c DESC LIMIT ?
                """, arguments: [sessionId, limit]).map { row in
                (tool: (row["tool"] as String?) ?? "?", count: row["c"] as Int)
            }
        }) ?? []
    }

    /// `repoURL` is a PURE lookup (a cache hit) - never shell git in here; the caller resolves and
    /// memoizes repo URLs off the main thread (see AppModel) and passes a closure that just reads
    /// the cache, so a refresh stays a cheap DB read.
    public func summaries(limit: Int = 20, now: Date = Date(), pricing: PricingTable? = nil,
                          repoURL: (String?) -> URL? = { _ in nil }) -> [SessionSummary] {
        (try? db.dbQueue.read { db -> [SessionSummary] in
            let sessions = try Row.fetchAll(db, sql: """
                SELECT id, project_path, model, started_at, last_seen_at FROM sessions
                ORDER BY last_seen_at DESC LIMIT ?
                """, arguments: [limit])

            return try sessions.map { row -> SessionSummary in
                let id: String = row["id"]
                let model: String? = row["model"]
                let lastSeen: Date? = row["last_seen_at"]
                let tokens = try Row.fetchOne(db, sql: """
                    SELECT COALESCE(SUM(input),0) AS i, COALESCE(SUM(output),0) AS o,
                           COALESCE(SUM(cache_read),0) AS cr, COALESCE(SUM(cache_write),0) AS cw
                    FROM token_usage WHERE session_id = ?
                    """, arguments: [id])
                let i: Int = tokens?["i"] ?? 0, o: Int = tokens?["o"] ?? 0
                let cr: Int = tokens?["cr"] ?? 0, cw: Int = tokens?["cw"] ?? 0
                let toolCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tool_events WHERE session_id = ?", arguments: [id]) ?? 0
                let recent = try String.fetchAll(db, sql: """
                    SELECT tool FROM tool_events WHERE session_id = ? ORDER BY id DESC LIMIT 6
                    """, arguments: [id])

                let projectPath: String? = row["project_path"]
                let active = lastSeen.map { now.timeIntervalSince($0) < activeWindow } ?? false
                return SessionSummary(
                    id: id,
                    projectName: Self.friendlyProject(projectPath),
                    model: model,
                    toolCount: toolCount,
                    inputTokens: i,
                    outputTokens: o,
                    cacheTokens: cr + cw,
                    costUSD: pricing?.cost(model: model, input: i, output: o, cacheRead: cr, cacheWrite: cw),
                    projectPath: projectPath,
                    startedAt: row["started_at"],
                    lastSeen: lastSeen,
                    active: active,
                    recentTools: recent,
                    repoURL: repoURL(projectPath)
                )
            }
        }) ?? []
    }
}
