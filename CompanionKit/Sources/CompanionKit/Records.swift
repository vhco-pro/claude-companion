import Foundation
import GRDB

// GRDB record types for schema v1. snake_case columns mapped via CodingKeys.

public struct SessionRecord: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "sessions"
    public var id: String
    public var projectPath: String?
    public var model: String?
    public var startedAt: Date?
    public var lastSeenAt: Date?
    public var status: String?
    enum CodingKeys: String, CodingKey {
        case id, model, status
        case projectPath = "project_path"
        case startedAt = "started_at"
        case lastSeenAt = "last_seen_at"
    }
}

public struct ToolEventRecord: Codable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "tool_events"
    public var id: Int64?
    public var sessionId: String?
    public var ts: Date?
    public var tool: String?
    public var bashCommand: String?
    public var targetPath: String?
    enum CodingKeys: String, CodingKey {
        case id, ts, tool
        case sessionId = "session_id"
        case bashCommand = "bash_command"
        case targetPath = "target_path"
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct TokenUsageRecord: Codable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "token_usage"
    public var id: Int64?
    public var sessionId: String?
    public var ts: Date?
    public var input: Int?
    public var output: Int?
    public var cacheRead: Int?
    public var cacheWrite: Int?
    enum CodingKeys: String, CodingKey {
        case id, ts, input, output
        case sessionId = "session_id"
        case cacheRead = "cache_read"
        case cacheWrite = "cache_write"
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct AuditRecord: Codable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "audit"
    public var id: Int64?
    public var ts: String
    public var sessionId: String?
    public var promptId: String?
    public var tool: String?
    public var command: String?
    public var decision: String
    public var ruleMatched: String?
    enum CodingKeys: String, CodingKey {
        case id, ts, tool, command, decision
        case sessionId = "session_id"
        case promptId = "prompt_id"
        case ruleMatched = "rule_matched"
    }
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct PricingRecord: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "pricing"
    public var model: String
    public var inputPerMtok: Double?
    public var outputPerMtok: Double?
    public var cacheReadPerMtok: Double?
    public var cacheWritePerMtok: Double?
    enum CodingKeys: String, CodingKey {
        case model
        case inputPerMtok = "input_per_mtok"
        case outputPerMtok = "output_per_mtok"
        case cacheReadPerMtok = "cache_read_per_mtok"
        case cacheWritePerMtok = "cache_write_per_mtok"
    }
}
