import XCTest
import CompanionCore
@testable import CompanionKit

final class SessionMonitorTests: XCTestCase {
    // MARK: Parser
    private let assistantLine = #"""
    {"type":"assistant","sessionId":"s1","cwd":"/Users/me/code/myproj","timestamp":"2026-06-15T10:00:00Z","message":{"model":"claude-opus-4-8","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":2000,"cache_creation_input_tokens":300},"content":[{"type":"text","text":"hi"},{"type":"tool_use","name":"Bash","input":{"command":"ls -la"}},{"type":"tool_use","name":"Edit","input":{"file_path":"/x/y.swift"}}]}}
    """#

    func testParsesAssistantEvent() {
        let e = JSONLParser.parse(assistantLine)!
        XCTAssertEqual(e.type, "assistant")
        XCTAssertEqual(e.sessionId, "s1")
        XCTAssertEqual(e.cwd, "/Users/me/code/myproj")
        XCTAssertEqual(e.model, "claude-opus-4-8")
        XCTAssertEqual(e.usage, ParsedUsage(input: 100, output: 50, cacheRead: 2000, cacheWrite: 300))
        XCTAssertEqual(e.toolUses, [
            ParsedToolUse(name: "Bash", command: "ls -la", filePath: nil),
            ParsedToolUse(name: "Edit", command: nil, filePath: "/x/y.swift"),
        ])
    }

    func testParsesUserEventWithoutUsageOrTools() {
        let e = JSONLParser.parse(#"{"type":"user","sessionId":"s1","message":{"role":"user","content":"hello"}}"#)!
        XCTAssertEqual(e.type, "user")
        XCTAssertNil(e.usage)
        XCTAssertTrue(e.toolUses.isEmpty)
    }

    func testToleratesUnknownTypeAndMalformed() {
        XCTAssertEqual(JSONLParser.parse(#"{"type":"file-history-snapshot","snapshot":{}}"#)?.type, "file-history-snapshot")
        XCTAssertNil(JSONLParser.parse("{not json"))
        XCTAssertNil(JSONLParser.parse(""))
    }

    // MARK: Ingestor
    private func tempDB() throws -> (AppDatabase, String) {
        let dir = NSTemporaryDirectory() + "cc-sm-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return (try AppDatabase(path: dir + "/companion.db"), dir)
    }

    func testIngestBuildsSessionSummary() throws {
        let (db, dir) = try tempDB(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let ing = SessionIngestor(db: db)
        let e = JSONLParser.parse(assistantLine)!
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        ing.ingest(e, now: t0)
        ing.ingest(e, now: t0.addingTimeInterval(60)) // second turn, same session

        let summaries = ing.summaries(now: t0.addingTimeInterval(120))
        XCTAssertEqual(summaries.count, 1)
        let s = summaries[0]
        XCTAssertEqual(s.id, "s1")
        XCTAssertEqual(s.projectName, "myproj")          // last path component of cwd
        XCTAssertEqual(s.model, "claude-opus-4-8")
        XCTAssertEqual(s.inputTokens, 200)               // 100 × 2 turns
        XCTAssertEqual(s.outputTokens, 100)
        XCTAssertEqual(s.toolCount, 4)                   // 2 tools × 2 turns
        XCTAssertEqual(Set(s.recentTools), ["Bash", "Edit"])
        XCTAssertTrue(s.active)                           // within window
    }

    func testStaleSessionMarkedInactive() throws {
        let (db, dir) = try tempDB(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let ing = SessionIngestor(db: db)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        ing.ingest(JSONLParser.parse(assistantLine)!, now: t0)
        let s = ing.summaries(now: t0.addingTimeInterval(60 * 60))[0]  // 1h later
        XCTAssertFalse(s.active)
    }

    func testTailerIngestsAndResumesFromOffset() throws {
        let (db, dir) = try tempDB(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let projects = dir + "/projects", projA = projects + "/proj-a"
        try FileManager.default.createDirectory(atPath: projA, withIntermediateDirectories: true)
        let file = projA + "/sess1.jsonl"
        let line = assistantLine + "\n"
        try (line + line).write(toFile: file, atomically: true, encoding: .utf8)  // 2 turns

        let ing = SessionIngestor(db: db)
        let tailer = JSONLTailer(ingestor: ing, projectsDir: projects, offsetsPath: dir + "/offsets.json")
        tailer.scanOnce()
        XCTAssertEqual(ing.summaries().first?.inputTokens, 200)   // 100 × 2
        XCTAssertEqual(ing.summaries().first?.toolCount, 4)

        // append a third turn → incremental, no double-count of the first two
        let fh = FileHandle(forWritingAtPath: file)!
        fh.seekToEndOfFile(); fh.write(Data(line.utf8)); try fh.close()
        tailer.scanOnce()
        XCTAssertEqual(ing.summaries().first?.inputTokens, 300)   // 100 × 3
        XCTAssertEqual(ing.summaries().first?.toolCount, 6)
    }
}
