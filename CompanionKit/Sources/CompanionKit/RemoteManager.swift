import CompanionCore
import Foundation

/// The layout of Claude Companion + Claude Code files on a remote host, rooted at the remote
/// `$HOME`. Pure value type so path construction is unit-tested without SSH. Mirrors the local
/// layout but stays POSIX (the remote is Linux), and uses a SPACE-FREE config path - same
/// root-cause rule as local (Claude Code's unquoted hook invocation can't run a spaced path).
public struct RemotePaths: Equatable, Sendable {
    public let home: String
    public init(home: String) { self.home = home.hasSuffix("/") ? String(home.dropLast()) : home }

    public var configDir: String { home + "/.config/claude-companion" }
    public var hook: String { configDir + "/companion-hook" }
    public var hookVersionMarker: String { configDir + "/.hook-version" }
    public var rulesCompiled: String { configDir + "/rules.compiled.json" }
    public var blocklist: String { configDir + "/blocklist.db" }
    public var auditLog: String { configDir + "/audit.ndjson" }
    public var claudeDir: String { home + "/.claude" }
    public var settings: String { claudeDir + "/settings.json" }
    public var settingsBackup: String { settings + ".companion-bak" }
}

/// Orchestrates remote-SSH hosts over plain `ssh`/`scp` - no daemon on the remote. Installs the
/// Linux hook + current rules, merge-tags the remote settings, and pushes rule updates. The
/// audit/session PULL loop lives in P4 (AppModel). Live methods are integration-tested against a
/// real host (the Fedora box, P6); the pure helpers here are unit-tested.
public struct RemoteManager: Sendable {
    let ssh: any SSHClient
    let hookProvider: LinuxHookProvider
    let localRulesCompiled: String
    let localBlocklist: String

    /// The hook version this app would install on a remote (used by sync to record what it pushed).
    public var hookVersion: String { hookProvider.version }

    public init(ssh: any SSHClient = SSHRunner(),
                hookProvider: LinuxHookProvider = LinuxHookProvider(),
                localRulesCompiled: String = Paths.rulesCompiled,
                localBlocklist: String = Paths.blocklist) {
        self.ssh = ssh
        self.hookProvider = hookProvider
        self.localRulesCompiled = localRulesCompiled
        self.localBlocklist = localBlocklist
    }

    /// Resolve the remote `$HOME` (so hook paths in settings.json are absolute + space-free).
    public func remotePaths(host: String) throws -> RemotePaths {
        let home = try ssh.run(host: host, command: "printf %s \"$HOME\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !home.isEmpty else { throw RemoteError.commandFailed(code: 0, stderr: "empty $HOME") }
        return RemotePaths(home: home)
    }

    /// Detect the remote CPU arch as our asset token (x86_64 / aarch64).
    public func detectArch(host: String) throws -> String {
        let uname = try ssh.run(host: host, command: "uname -m")
        guard let arch = LinuxHookProvider.arch(forUname: uname) else {
            throw LinuxHookProvider.HookError.unsupportedArch(uname.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return arch
    }

    /// Register a host: push the arch-matched hook (only if its version changed) + current rules,
    /// then merge-tag the remote `settings.json`. Returns the resolved remote layout so the caller
    /// can persist it. The user must RELOAD the VSCode window after this (the extension host
    /// snapshots hooks at start) - surfaced by the UI.
    @discardableResult
    public func register(host: String) async throws -> RemotePaths {
        let rp = try remotePaths(host: host)
        try ssh.run(host: host, command: "mkdir -p \(sh(rp.configDir)) \(sh(rp.claudeDir))")
        _ = try await ensureHookCurrent(host: host, paths: rp)
        try pushRules(host: host, paths: rp)
        try installSettings(host: host, paths: rp)
        return rp
    }

    /// Bring the remote hook to THIS app's version, version-gated: read the remote `.hook-version`
    /// marker and, only if it differs, download the arch-matched hook (checksum-verified, ~55 MB),
    /// upload it, `chmod 755`, and write the new marker. Returns whether it actually pushed (so the
    /// caller can nudge a window reload). Called by both `register` and the periodic sync, so the
    /// remote hook self-heals after an app upgrade instead of needing a manual Remove/re-Add.
    @discardableResult
    public func ensureHookCurrent(host: String, paths: RemotePaths? = nil) async throws -> Bool {
        let rp = try paths ?? remotePaths(host: host)
        let installed = (try? ssh.run(host: host, command: "cat \(sh(rp.hookVersionMarker)) 2>/dev/null"))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard installed != hookProvider.version else { return false }   // already current → no transfer
        let arch = try detectArch(host: host)
        let localHook = try await hookProvider.ensure(arch: arch)        // only fetched on a real change
        try ssh.run(host: host, command: "mkdir -p \(sh(rp.configDir))")
        try ssh.upload(localPath: localHook, to: host, remotePath: rp.hook)
        try ssh.run(host: host, command: "chmod 755 \(sh(rp.hook))")
        try ssh.run(host: host, command: "printf %s \(sh(hookProvider.version)) > \(sh(rp.hookVersionMarker))")
        return true
    }

    /// Re-assert that our hook is wired into the remote `settings.json`. Claude Code rewrites that
    /// file on its own (e.g. a `/config` change) and can drop our `hooks` block, silently disabling
    /// the gate. Cheap grep for our `companion-hook` marker; only if absent do the idempotent
    /// pull-merge-push `installSettings` (preserving the user's other keys). Returns whether it
    /// re-wired (so the caller can nudge a window reload). Called by the periodic sync.
    @discardableResult
    public func ensureSettingsWired(host: String, paths: RemotePaths? = nil) throws -> Bool {
        let rp = try paths ?? remotePaths(host: host)
        let wired = ((try? ssh.run(host: host, command:
            "grep -qF companion-hook \(sh(rp.settings)) 2>/dev/null && echo y || echo n"))?
            .trimmingCharacters(in: .whitespacesAndNewlines)) == "y"
        guard !wired else { return false }
        try installSettings(host: host, paths: rp)
        return true
    }

    /// Push the compiled rules + blocklist to a remote (takes effect on its next tool call, since
    /// the hook reads them fresh). A failed push leaves the last-good remote files intact, so the
    /// remote keeps gating with the previous rules (never silently degrades).
    public func pushRules(host: String, paths: RemotePaths? = nil) throws {
        let rp = try paths ?? remotePaths(host: host)
        try ssh.run(host: host, command: "mkdir -p \(sh(rp.configDir))")
        try ssh.upload(localPath: localRulesCompiled, to: host, remotePath: rp.rulesCompiled)
        if FileManager.default.fileExists(atPath: localBlocklist) {
            try ssh.upload(localPath: localBlocklist, to: host, remotePath: rp.blocklist)
        }
    }

    /// Deregister: remove only our hook entries from the remote settings (preserving any other
    /// hooks / keys), mirroring the local uninstall. The pre-install backup is left in place as a
    /// safety net.
    public func deregister(host: String) throws {
        let rp = try remotePaths(host: host)
        try editRemoteSettings(host: host, paths: rp) { installer in try installer.uninstall() }
    }

    // MARK: settings.json pull-merge-push

    private func installSettings(host: String, paths rp: RemotePaths) throws {
        // Back up the remote settings before first touch (only if it exists).
        try ssh.run(host: host,
            command: "[ -f \(sh(rp.settings)) ] && cp \(sh(rp.settings)) \(sh(rp.settingsBackup)) || true")
        try editRemoteSettings(host: host, paths: rp) { installer in try installer.install() }
    }

    /// Pull the remote settings to a temp file, run the structure-preserving `SettingsInstaller`
    /// against it with the REMOTE hook path, push it back. Same merge code as local, so it coexists
    /// with the user's other remote hooks and preserves unknown top-level keys.
    private func editRemoteSettings(host: String, paths rp: RemotePaths,
                                    _ body: (SettingsInstaller) throws -> Void) throws {
        let tmpDir = NSTemporaryDirectory() + "cc-remote-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }
        let tmp = tmpDir + "/settings.json"

        // Pull if it exists; otherwise start from an empty file (installer creates the hooks key).
        let exists = ((try? ssh.run(host: host, command: "test -f \(sh(rp.settings)) && echo y || echo n"))?
            .trimmingCharacters(in: .whitespacesAndNewlines)) == "y"
        if exists {
            try ssh.download(from: host, remotePath: rp.settings, to: tmp)
        } else {
            try Data("{}".utf8).write(to: URL(fileURLWithPath: tmp))
        }

        let installer = SettingsInstaller(settingsPath: tmp, hookCommand: rp.hook)
        try body(installer)
        try ssh.upload(localPath: tmp, to: host, remotePath: rp.settings)
    }

    /// Single-quote a path for safe interpolation into a remote shell command.
    func sh(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
