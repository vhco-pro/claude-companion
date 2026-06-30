import XCTest
import CompanionCore
import GRDB
@testable import CompanionKit

/// Plan 13 - remote hook auto-update on sync. Uses a FakeSSH (no real host) + the mocked download
/// path (MockURLProtocol from RemoteManagerTests) to exercise the version-gate and the best-effort
/// resilience that keeps the audit/session pull working even when a hook push fails.
final class RemoteHookAutosyncTests: XCTestCase {

    /// Records commands + uploads and returns canned output. Pattern-matches the few commands the
    /// hook-update + audit-pull paths issue.
    final class FakeSSH: SSHClient, @unchecked Sendable {
        var markerValue = "0.0.1"          // remote .hook-version contents
        var uname = "x86_64"
        var failUpload = false
        var settingsWired = true           // what the grep for our marker in settings.json reports
        var uploads: [(local: String, remote: String)] = []
        var commands: [String] = []
        var dataFor: ((String) -> Data)?   // override runData per command

        func run(host: String, command: String) throws -> String {
            commands.append(command)
            if command.contains("$HOME") { return "/home/m" }
            if command.contains("cat") && command.contains(".hook-version") { return markerValue }
            if command.contains("grep") && command.contains("companion-hook") { return settingsWired ? "y" : "n" }
            if command.contains("uname") { return uname }
            return ""
        }
        func runData(host: String, command: String) throws -> Data { dataFor?(command) ?? Data() }
        func upload(localPath: String, to host: String, remotePath: String) throws {
            if failUpload { throw RemoteError.commandFailed(code: 1, stderr: "scp failed") }
            uploads.append((localPath, remotePath))
        }
        func download(from host: String, remotePath: String, to localPath: String) throws {}
    }

    private func mockProvider(version: String = "9.9.9") -> LinuxHookProvider {
        let payload = Data("fake-hook".utf8)
        let good = LinuxHookProvider.sha256Hex(payload)
        let base = "https://github.com/test/repo/releases/download/v\(version)/companion-hook-linux-x86_64"
        MockURLProtocol.responses = [
            base: (payload, 200),
            base + ".sha256": (Data("\(good)  companion-hook-linux-x86_64\n".utf8), 200),
        ]
        return LinuxHookProvider(version: version, repoSlug: "test/repo", session: MockURLProtocol.session())
    }

    // MARK: ensureHookCurrent version-gate

    func testPushesWhenRemoteVersionIsStale() async throws {
        let dir = NSTemporaryDirectory() + "cc-eh-\(UUID().uuidString)"
        setenv("COMPANION_CONFIG_DIR", dir, 1)
        defer { unsetenv("COMPANION_CONFIG_DIR"); try? FileManager.default.removeItem(atPath: dir) }

        let fake = FakeSSH(); fake.markerValue = "0.0.1"
        let mgr = RemoteManager(ssh: fake, hookProvider: mockProvider(version: "9.9.9"))

        let pushed = try await mgr.ensureHookCurrent(host: "h", paths: RemotePaths(home: "/home/m"))
        XCTAssertTrue(pushed)
        XCTAssertEqual(fake.uploads.count, 1)
        XCTAssertEqual(fake.uploads.first?.remote, "/home/m/.config/claude-companion/companion-hook")
        // marker rewritten to the new version
        XCTAssertTrue(fake.commands.contains { $0.contains("printf %s") && $0.contains(".hook-version") && $0.contains("9.9.9") })
    }

    func testSkipsWhenRemoteVersionMatches() async throws {
        MockURLProtocol.responses = [:]   // no network should be needed
        let fake = FakeSSH(); fake.markerValue = "9.9.9"
        let mgr = RemoteManager(ssh: fake, hookProvider: LinuxHookProvider(version: "9.9.9", repoSlug: "test/repo"))
        let pushed = try await mgr.ensureHookCurrent(host: "h", paths: RemotePaths(home: "/home/m"))
        XCTAssertFalse(pushed)
        XCTAssertEqual(fake.uploads.count, 0)
        XCTAssertFalse(fake.commands.contains { $0.contains("uname") })   // never even detected arch
    }

    // MARK: ensureSettingsWired (plan 15 fix 1) - self-heal the settings.json hook wiring

    func testEnsureSettingsWiredNoOpWhenAlreadyWired() throws {
        let fake = FakeSSH(); fake.settingsWired = true
        let mgr = RemoteManager(ssh: fake, hookProvider: LinuxHookProvider(version: "1", repoSlug: "t/r"))
        let rewired = try mgr.ensureSettingsWired(host: "h", paths: RemotePaths(home: "/home/m"))
        XCTAssertFalse(rewired)
        XCTAssertTrue(fake.uploads.isEmpty, "must not touch settings when already wired")
    }

    func testEnsureSettingsWiredReinstallsWhenMarkerMissing() throws {
        let fake = FakeSSH(); fake.settingsWired = false
        let mgr = RemoteManager(ssh: fake, hookProvider: LinuxHookProvider(version: "1", repoSlug: "t/r"))
        let rewired = try mgr.ensureSettingsWired(host: "h", paths: RemotePaths(home: "/home/m"))
        XCTAssertTrue(rewired)
        XCTAssertTrue(fake.uploads.contains { $0.remote == "/home/m/.claude/settings.json" },
                      "missing wiring → pull-merge-push settings.json")
    }

    // MARK: reload-reminder once-per-version (pure)

    func testShouldRemindReloadOncePerVersion() {
        XCTAssertTrue(RemoteState.shouldRemindReload(hookVersion: "1.2.0", lastReminded: nil))
        XCTAssertTrue(RemoteState.shouldRemindReload(hookVersion: "1.2.0", lastReminded: "1.1.0"))
        XCTAssertFalse(RemoteState.shouldRemindReload(hookVersion: "1.2.0", lastReminded: "1.2.0"))
        XCTAssertFalse(RemoteState.shouldRemindReload(hookVersion: nil, lastReminded: "1.2.0"))
    }

    // MARK: sync resilience - a hook push failure must NOT block the audit pull

    func testSyncStillPullsWhenHookPushFails() async throws {
        let dir = NSTemporaryDirectory() + "cc-sr-\(UUID().uuidString)"
        setenv("COMPANION_CONFIG_DIR", dir, 1)
        defer { unsetenv("COMPANION_CONFIG_DIR"); try? FileManager.default.removeItem(atPath: dir) }

        let fake = FakeSSH()
        fake.markerValue = "0.0.1"          // stale → triggers a push…
        fake.failUpload = true              // …which fails
        let auditLine = "{\"decision\":\"deny\",\"ts\":\"2026-06-30T00:00:00Z\",\"command\":\"rm -rf /\",\"sessionId\":\"x\",\"tool\":\"Bash\"}\n"
        fake.dataFor = { cmd in cmd.contains("audit.ndjson") ? Data(auditLine.utf8) : Data() }

        let db = try AppDatabase.open()
        let mgr = RemoteManager(ssh: fake, hookProvider: mockProvider(version: "9.9.9"))
        let sync = RemoteSync(db: db, manager: mgr, ssh: fake)

        let ok = await sync.syncOnce(Remote(alias: "h"))
        XCTAssertTrue(ok, "pull should succeed even though the hook push failed")

        let denies = try await db.dbQueue.read { db in
            try AuditRecord.filter(Column("host") == "h" && Column("decision") == "deny").fetchCount(db)
        }
        XCTAssertGreaterThan(denies, 0, "remote audit was still ingested")

        let st = RemoteStateStore().load(alias: "h")
        XCTAssertTrue(st.reachable)
        XCTAssertNotNil(st.lastSync)
        XCTAssertTrue(st.lastError?.contains("hook") ?? false, "hook failure surfaced as lastError")
    }
}
