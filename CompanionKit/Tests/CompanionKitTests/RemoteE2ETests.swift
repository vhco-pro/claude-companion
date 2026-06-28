import XCTest
import CompanionCore
import GRDB
@testable import CompanionKit

/// Live end-to-end against a REAL remote-SSH host (P6 of remote-ssh.plan.md). Skipped unless
/// RUN_REMOTE_E2E=1, so it never runs in CI / the normal suite. Drives the actual code paths -
/// register → gate on the remote → pull audit back host-tagged → kill-switch propagation - then
/// cleans up after itself (deregister + restore).
///
/// Run:
///   RUN_REMOTE_E2E=1 E2E_HOST=<alias> \
///   E2E_LINUX_HOOK=$PWD/.build/x86_64-swift-linux-musl/release/companion-hook \
///   swift test --filter RemoteE2ETests
final class RemoteE2ETests: XCTestCase {
    func testRemoteSSHEndToEnd() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["RUN_REMOTE_E2E"] == "1", "set RUN_REMOTE_E2E=1 to run the live test")
        let host = env["E2E_HOST"] ?? "fedora-43.tail6948f.ts.net"
        let linuxHook = try XCTUnwrap(env["E2E_LINUX_HOOK"], "set E2E_LINUX_HOOK to a local linux companion-hook")

        // Isolated config dir so we never touch the developer's real ~/.config/claude-companion.
        let cfg = NSTemporaryDirectory() + "cc-e2e-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: cfg, withIntermediateDirectories: true)
        setenv("COMPANION_CONFIG_DIR", cfg, 1)
        defer { unsetenv("COMPANION_CONFIG_DIR"); try? FileManager.default.removeItem(atPath: cfg) }

        // Real shipped rules → rules.compiled.json (what we push to the remote).
        let rules = RulesManager()
        rules.ensureDefaultRules()
        _ = try rules.compile()
        XCTAssertTrue(FileManager.default.fileExists(atPath: Paths.rulesCompiled), "compiled rules missing")

        // Seed the linux-hook cache so register() skips the download (no published release yet).
        let provider = LinuxHookProvider(version: "e2e")
        let cached = Paths.linuxHook(version: "e2e", arch: "x86_64")
        try FileManager.default.createDirectory(
            atPath: (cached as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: linuxHook, toPath: cached)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cached)

        let ssh = SSHRunner()
        let manager = RemoteManager(ssh: ssh, hookProvider: provider)
        var registered = false
        defer { if registered { try? manager.deregister(host: host) } }   // restore remote settings

        // ── 1. REGISTER ──────────────────────────────────────────────────────────────
        let rp = try await manager.register(host: host)
        registered = true

        // ── 2. INSTALL ASSERTIONS ────────────────────────────────────────────────────
        func remote(_ cmd: String) throws -> String {
            try ssh.run(host: host, command: cmd).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        XCTAssertEqual(try remote("test -x \(rp.hook) && echo yes || echo no"), "yes", "remote hook not executable")
        XCTAssertEqual(try remote("test -f \(rp.rulesCompiled) && echo yes || echo no"), "yes", "rules not pushed")
        XCTAssertTrue(try remote("cat \(rp.settings)").contains("companion-hook"), "settings.json not merge-tagged")

        // ── 3. GATE RUNS ON THE REMOTE ───────────────────────────────────────────────
        func decide(_ command: String) throws -> String {
            let payload = #"{"hook_event_name":"PreToolUse","session_id":"e2e","tool_name":"Bash","tool_input":{"command":"\#(command)"}}"#
            let out = try ssh.run(host: host, command: "printf '%s' '\(payload)' | \(rp.hook)")
            struct Out: Decodable { struct Inner: Decodable { let permissionDecision: String }; let hookSpecificOutput: Inner }
            return try JSONDecoder().decode(Out.self, from: Data(out.utf8)).hookSpecificOutput.permissionDecision
        }
        XCTAssertEqual(try decide("ls -la"), "allow", "benign cmd should auto-allow on the remote")
        XCTAssertEqual(try decide("rm -rf /"), "deny", "catastrophic cmd should be denied on the remote")
        XCTAssertEqual(try decide("git push"), "allow", "plain git push is allowed by design")
        XCTAssertEqual(try decide("git push --force origin main"), "ask", "force-push should ask on the remote")

        // ── 4. PULL: remote decisions come back host-tagged ──────────────────────────
        let db = try AppDatabase.open()
        let sync = RemoteSync(db: db, manager: manager, ssh: ssh)
        sync.sessionWindowMinutes = 60
        _ = sync.syncOnce(Remote(alias: host))   // audit ingest happens before sessions, so denies land regardless
        let denies = try await db.dbQueue.read { db in
            try AuditRecord.filter(Column("host") == host && Column("decision") == "deny").fetchCount(db)
        }
        XCTAssertGreaterThan(denies, 0, "no host-tagged deny pulled back from the remote")

        // ── 5. KILL-SWITCH PROPAGATION ───────────────────────────────────────────────
        _ = try rules.setAutoAccept(false)
        try sync.pushRules(to: Remote(alias: host))
        XCTAssertEqual(try decide("echo hello"), "ask", "kill-switch (auto_accept off) did not propagate to the remote")
        _ = try rules.setAutoAccept(true)
        try sync.pushRules(to: Remote(alias: host))   // restore the remote to auto-accept
    }
}
