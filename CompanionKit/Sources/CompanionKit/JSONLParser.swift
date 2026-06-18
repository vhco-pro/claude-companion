import Foundation

// Parses one line of a Claude Code session JSONL (~/.claude/projects/<enc>/<uuid>.jsonl) into a
// structured event. Shapes confirmed by recon (2026-06-15, Claude Code 2.1.177): the token/tool
// payload lives under `.message`; session/cwd/timestamp are top-level. Tolerant by design —
// unknown types and missing fields never throw (forward-compatible with JSONL drift).

public struct ParsedUsage: Equatable, Sendable {
    public let input: Int
    public let output: Int
    public let cacheRead: Int
    public let cacheWrite: Int
}

public struct ParsedToolUse: Equatable, Sendable {
    public let name: String
    public let command: String?   // Bash
    public let filePath: String?  // Edit/Write/Read
}

public struct ParsedEvent: Sendable {
    public let type: String
    public let sessionId: String?
    public let cwd: String?
    public let model: String?
    public let timestamp: String?
    public let usage: ParsedUsage?
    public let toolUses: [ParsedToolUse]
}

public enum JSONLParser {
    public static func parse(_ line: String) -> ParsedEvent? {
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }

        let message = obj["message"] as? [String: Any]

        var usage: ParsedUsage?
        if let u = message?["usage"] as? [String: Any] {
            usage = ParsedUsage(
                input: (u["input_tokens"] as? Int) ?? 0,
                output: (u["output_tokens"] as? Int) ?? 0,
                cacheRead: (u["cache_read_input_tokens"] as? Int) ?? 0,
                cacheWrite: (u["cache_creation_input_tokens"] as? Int) ?? 0
            )
        }

        var tools: [ParsedToolUse] = []
        if let content = message?["content"] as? [[String: Any]] {
            for item in content where (item["type"] as? String) == "tool_use" {
                let input = item["input"] as? [String: Any]
                tools.append(ParsedToolUse(
                    name: (item["name"] as? String) ?? "?",
                    command: input?["command"] as? String,
                    filePath: input?["file_path"] as? String
                ))
            }
        }

        return ParsedEvent(
            type: (obj["type"] as? String) ?? "unknown",
            sessionId: obj["sessionId"] as? String,
            cwd: obj["cwd"] as? String,
            model: message?["model"] as? String,
            timestamp: obj["timestamp"] as? String,
            usage: usage,
            toolUses: tools
        )
    }
}
