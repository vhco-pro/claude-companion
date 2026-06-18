import CompanionCore
import Foundation
import GRDB

/// The app-owned SQLite store (GRDB). The hook never opens this - it appends `audit.ndjson`,
/// which the app ingests here. Single-writer (the app), so a DatabaseQueue is sufficient.
public final class AppDatabase {
    public let dbQueue: DatabaseQueue

    public init(path: String) throws {
        dbQueue = try DatabaseQueue(path: path)
        try Self.migrator.migrate(dbQueue)
    }

    /// Open the store at the resolved config-dir path (creating the dir if needed).
    public static func open(at path: String = Paths.database) throws -> AppDatabase {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return try AppDatabase(path: path)
    }

    /// Forward-only migrations. GRDB tracks applied versions in its own `grdb_migrations`
    /// table (this replaces the hand-rolled `schema_meta` from the spec).
    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "sessions") { t in
                t.column("id", .text).primaryKey()
                t.column("project_path", .text)
                t.column("model", .text)
                t.column("started_at", .datetime)
                t.column("last_seen_at", .datetime)
                t.column("status", .text)
            }
            try db.create(table: "tool_events") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("session_id", .text).indexed()
                t.column("ts", .datetime)
                t.column("tool", .text)
                t.column("bash_command", .text)
                t.column("target_path", .text)
            }
            try db.create(table: "token_usage") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("session_id", .text).indexed()
                t.column("ts", .datetime)
                t.column("input", .integer)
                t.column("output", .integer)
                t.column("cache_read", .integer)
                t.column("cache_write", .integer)
            }
            try db.create(table: "audit") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("ts", .datetime)
                t.column("session_id", .text)
                t.column("prompt_id", .text)
                t.column("tool", .text)
                t.column("command", .text)
                t.column("decision", .text)
                t.column("rule_matched", .text)
            }
            try db.create(table: "pricing") { t in
                t.column("model", .text).primaryKey()
                t.column("input_per_mtok", .double)
                t.column("output_per_mtok", .double)
                t.column("cache_read_per_mtok", .double)
                t.column("cache_write_per_mtok", .double)
            }
        }
        return m
    }
}
