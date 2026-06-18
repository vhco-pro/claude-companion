import Foundation

/// One decision row appended to audit.ndjson by the hook; the app ingests these into SQLite.
/// Codable both ways: the hook encodes it, the app decodes the same shape.
public struct AuditEntry: Codable, Sendable {
    public let ts: String          // ISO8601
    public let sessionId: String?
    public let tool: String?
    public let command: String?
    public let decision: String
    public let ruleMatched: String?

    public init(ts: String, sessionId: String?, tool: String?, command: String?,
                decision: String, ruleMatched: String?) {
        self.ts = ts
        self.sessionId = sessionId
        self.tool = tool
        self.command = command
        self.decision = decision
        self.ruleMatched = ruleMatched
    }
}

public enum AuditWriter {
    /// Atomic append of one NDJSON line. `O_APPEND` + a single `write()` is atomic for small
    /// records, so concurrent hook processes never interleave (foundation shared-state model).
    public static func append(_ entry: AuditEntry, toPath path: String) {
        guard var data = try? JSONEncoder().encode(entry) else { return }
        data.append(0x0A) // newline
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }
}
