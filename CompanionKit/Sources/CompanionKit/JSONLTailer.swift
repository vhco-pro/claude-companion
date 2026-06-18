import CompanionCore
import Foundation

/// Tails every `~/.claude/projects/<enc>/<uuid>.jsonl` from a persisted per-file byte offset and
/// feeds parsed events to the SessionIngestor. Runs scans on a background queue (existing files
/// can be large); offsets persist so a restart is incremental, not a full re-ingest. Read-only on
/// ~/.claude.
public final class JSONLTailer {
    private let ingestor: SessionIngestor
    private let projectsDir: String
    private let offsetsPath: String
    private var offsets: [String: UInt64] = [:]
    private var watcher: FileWatcher?
    private let queue = DispatchQueue(label: "pro.vhco.companion.jsonl")
    private let onUpdate: () -> Void

    public init(ingestor: SessionIngestor,
                projectsDir: String = ("~/.claude/projects" as NSString).expandingTildeInPath,
                offsetsPath: String = Paths.configDir + "/jsonl-offsets.json",
                onUpdate: @escaping () -> Void = {}) {
        self.ingestor = ingestor
        self.projectsDir = projectsDir
        self.offsetsPath = offsetsPath
        self.onUpdate = onUpdate
    }

    public func start() {
        loadOffsets()
        queue.async { [weak self] in self?.scanAndNotify() }
        watcher = FileWatcher(paths: [projectsDir]) { [weak self] in
            self?.queue.async { self?.scanAndNotify() }
        }
        watcher?.start()
    }

    private func scanAndNotify() {
        scanOnce()
        DispatchQueue.main.async { self.onUpdate() }
    }

    /// Synchronous scan of all session files (used directly by tests).
    public func scanOnce() {
        for file in jsonlFiles() { tail(file) }
        saveOffsets()
    }

    private func jsonlFiles() -> [String] {
        // Recursive: catches both the main session file (projects/<enc>/<uuid>.jsonl) and nested
        // subagent transcripts (projects/<enc>/<uuid>/subagents/agent-*.jsonl). Subagents share
        // the parent sessionId, so their tokens/tools attribute to the right session (separate
        // API calls in separate files → additive, not double-counted).
        guard let en = FileManager.default.enumerator(atPath: projectsDir) else { return [] }
        var files: [String] = []
        for case let rel as String in en where rel.hasSuffix(".jsonl") {
            files.append(projectsDir + "/" + rel)
        }
        return files
    }

    private func tail(_ path: String) {
        guard let fh = FileHandle(forReadingAtPath: path) else { return }
        defer { try? fh.close() }
        let start = offsets[path] ?? 0
        try? fh.seek(toOffset: start)
        let data = fh.readDataToEndOfFile()
        guard !data.isEmpty else { return }
        let bytes = [UInt8](data)
        guard let lastNL = bytes.lastIndex(of: 0x0A) else { return }  // wait for a complete line
        let consumable = Data(bytes[0...lastNL])
        var items: [(event: ParsedEvent, at: Date)] = []
        for lineData in consumable.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let line = String(data: Data(lineData), encoding: .utf8),
                  let event = JSONLParser.parse(line) else { continue }
            let ts = event.timestamp.flatMap(Self.parseTimestamp) ?? Date()
            items.append((event, ts))
        }
        ingestor.ingestBatch(items)   // one transaction for the whole file
        offsets[path] = start + UInt64(lastNL + 1)
    }

    // MARK: timestamps

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    static func parseTimestamp(_ s: String) -> Date? {
        isoFractional.date(from: s) ?? isoPlain.date(from: s)
    }

    // MARK: offsets

    private func loadOffsets() {
        guard let data = FileManager.default.contents(atPath: offsetsPath),
              let obj = try? JSONDecoder().decode([String: UInt64].self, from: data) else { return }
        offsets = obj
    }

    private func saveOffsets() {
        guard let data = try? JSONEncoder().encode(offsets) else { return }
        try? data.write(to: URL(fileURLWithPath: offsetsPath), options: .atomic)
    }
}
