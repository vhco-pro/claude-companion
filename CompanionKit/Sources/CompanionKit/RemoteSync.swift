import CompanionCore
import Foundation
import GRDB

/// Pulls a remote host's decision audit + session transcripts back to the Mac over SSH and ingests
/// them host-tagged, and pushes rule updates out. No daemon on the remote: we incrementally mirror
/// the remote's append-only files (`tail -c +N` from the local mirror's size - Spike 3) into a
/// per-host local mirror, then let the EXISTING ingestors (which already handle offsets + partial
/// trailing lines) consume the mirror. Byte-exact (raw Data append) so a multibyte char split at a
/// pull boundary reassembles on the next pull.
///
/// @unchecked Sendable: it's used from a detached task. Its stored deps are immutable after init and
/// the DB is thread-safe (GRDB DatabaseQueue); ingestors only ever append via that queue.
public final class RemoteSync: @unchecked Sendable {
    private let db: AppDatabase
    private let manager: RemoteManager
    private let ssh: SSHRunner
    private let sessionIngestor: SessionIngestor
    private let stateStore: RemoteStateStore
    /// Only pull session files touched within this window (active work), not the full history.
    public var sessionWindowMinutes: Int = 180
    /// Remote cwd → repo web URL, resolved over SSH (local git can't see a remote path). Read by
    /// AppModel to seed its repo-link cache so remote sessions get quicklinks too.
    private let repoLock = NSLock()
    private var resolvedRepos: [String: URL] = [:]

    public init(db: AppDatabase,
                manager: RemoteManager = RemoteManager(),
                ssh: SSHRunner = SSHRunner(),
                stateStore: RemoteStateStore = RemoteStateStore()) {
        self.db = db
        self.manager = manager
        self.ssh = ssh
        self.sessionIngestor = SessionIngestor(db: db)
        self.stateStore = stateStore
    }

    // MARK: per-host mirror paths

    private func base(_ alias: String) -> String { Paths.remotesDir + "/" + Paths.sanitizeAlias(alias) }
    private func auditMirror(_ a: String) -> String { base(a) + ".audit.ndjson" }
    private func auditOffset(_ a: String) -> String { base(a) + ".audit.offset" }
    private func projectsMirror(_ a: String) -> String { base(a) + "/projects" }
    private func jsonlOffsets(_ a: String) -> String { base(a) + ".jsonl-offsets.json" }

    // MARK: pull

    /// Best-effort one-shot sync of a host (records status in its sidecar; never throws). Returns
    /// true if anything was reached/synced (so the caller can refresh the UI).
    @discardableResult
    public func syncOnce(_ remote: Remote) -> Bool {
        guard remote.enabled else { return false }
        var state = stateStore.load(alias: remote.alias)
        do {
            let rp = try manager.remotePaths(host: remote.alias)   // first contact = reachability probe
            state.reachable = true

            try mirror(host: remote.alias, remotePath: rp.auditLog, localPath: auditMirror(remote.alias))
            let ai = AuditIngestor(db: db, auditPath: auditMirror(remote.alias), offsetPath: auditOffset(remote.alias))
            _ = try ai.ingestNew(host: remote.alias)

            try pullSessions(alias: remote.alias, paths: rp)
            resolveRepoURLs(alias: remote.alias)

            state.lastError = nil
            state.lastSync = Date()
            stateStore.save(alias: remote.alias, state)
            return true
        } catch {
            state.lastError = Self.describe(error)
            if Self.isConnectionError(error) { state.reachable = false }
            stateStore.save(alias: remote.alias, state)
            return false
        }
    }

    private func pullSessions(alias: String, paths rp: RemotePaths) throws {
        let remoteProjects = rp.claudeDir + "/projects"
        // GNU find on Linux: %P prints the path relative to the search root.
        let list = try ssh.run(host: alias, command:
            "find \(manager.sh(remoteProjects)) -name '*.jsonl' -mmin -\(sessionWindowMinutes) -printf '%P\\n' 2>/dev/null || true")
        let rels = list.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        let localProjects = projectsMirror(alias)
        for rel in rels {
            try mirror(host: alias, remotePath: remoteProjects + "/" + rel, localPath: localProjects + "/" + rel)
        }
        // Reuse the local JSONL tailer over the mirror, tagging every session with the host.
        let tailer = JSONLTailer(ingestor: sessionIngestor, projectsDir: localProjects,
                                 offsetsPath: jsonlOffsets(alias), host: alias)
        tailer.scanOnce()
    }

    /// Resolve repo web URLs for this host's session cwds by reading their git origin OVER SSH
    /// (the cwd doesn't exist locally, so RepoResolver's local git can't help). The origin→web
    /// conversion is the same pure `RepoURL.web` the local path uses. Resolves each cwd once.
    private func resolveRepoURLs(alias: String) {
        let cwds = (try? db.dbQueue.read { db in
            try String.fetchAll(db, sql:
                "SELECT DISTINCT project_path FROM sessions WHERE host = ? AND project_path IS NOT NULL",
                arguments: [alias])
        }) ?? []
        for cwd in cwds {
            repoLock.lock(); let known = resolvedRepos[cwd] != nil; repoLock.unlock()
            if known { continue }
            let origin = ((try? ssh.run(host: alias,
                command: "git -C \(manager.sh(cwd)) config --get remote.origin.url 2>/dev/null")) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !origin.isEmpty, let url = RepoURL.web(from: origin) else { continue }
            repoLock.lock(); resolvedRepos[cwd] = url; repoLock.unlock()
        }
    }

    /// Snapshot of resolved remote cwd → repo web URL (for AppModel to seed its render cache).
    public func remoteRepoURLs() -> [String: URL] {
        repoLock.lock(); defer { repoLock.unlock() }
        return resolvedRepos
    }

    /// Append only the bytes the remote file has grown by since we last mirrored it (its local
    /// mirror's current size). Idempotent + incremental.
    private func mirror(host: String, remotePath: String, localPath: String) throws {
        let have = Self.fileSize(localPath)
        let new = try ssh.runData(host: host,
            command: "tail -c +\(have + 1) \(manager.sh(remotePath)) 2>/dev/null || true")
        guard !new.isEmpty else { return }
        try Self.append(new, to: localPath)
    }

    // MARK: push

    /// Push current compiled rules to one host (caller decides which / when - e.g. on recompile).
    public func pushRules(to remote: Remote) throws {
        guard remote.enabled else { return }
        try manager.pushRules(host: remote.alias)
    }

    // MARK: register / deregister (delegate to the manager)

    public func register(_ remote: Remote) async throws { try await manager.register(host: remote.alias) }
    public func deregister(_ remote: Remote) throws { try manager.deregister(host: remote.alias) }

    // MARK: helpers

    static func fileSize(_ path: String) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    static func append(_ data: Data, to path: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: path) { fm.createFile(atPath: path, contents: nil) }
        let fh = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? fh.close() }
        try fh.seekToEnd()
        try fh.write(contentsOf: data)
    }

    static func isConnectionError(_ error: Error) -> Bool {
        switch error {
        case RemoteError.unreachable, RemoteError.timeout, RemoteError.needsKey, RemoteError.localFailure:
            return true
        default: return false
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case RemoteError.unreachable: return "unreachable"
        case RemoteError.needsKey: return "needs an SSH key"
        case RemoteError.timeout: return "connection timed out"
        case let RemoteError.commandFailed(code, _): return "remote command failed (\(code))"
        case RemoteError.localFailure(let m): return m
        case let e as LinuxHookProvider.HookError: return "\(e)"
        default: return error.localizedDescription
        }
    }
}
