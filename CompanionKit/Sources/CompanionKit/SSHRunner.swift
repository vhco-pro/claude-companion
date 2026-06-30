import Foundation

/// A structured failure from an `ssh`/`scp` invocation, so the UI can show a precise status
/// ("unreachable" vs "needs a key" vs "the remote command failed") instead of a raw blob.
public enum RemoteError: Error, Equatable, Sendable {
    case unreachable(String)     // DNS/route/refused/timeout - host not reachable at all
    case needsKey(String)        // reached the host but auth failed (no usable key / agent)
    case timeout                 // our ConnectTimeout fired
    case commandFailed(code: Int32, stderr: String)   // reached + ran, remote exited nonzero
    case localFailure(String)    // couldn't even spawn ssh/scp locally

    /// Classify an `ssh` outcome. ssh uses exit 255 for its OWN connection/auth errors and passes
    /// through the remote command's exit code otherwise - so 255 = transport, anything else = the
    /// remote command actually ran and failed. Pure (no IO) so it's fully unit-tested.
    public static func classify(exitCode: Int32, stderr: String) -> RemoteError? {
        guard exitCode != 0 else { return nil }
        let s = stderr.lowercased()
        if exitCode == 255 {
            if s.contains("permission denied") || s.contains("publickey") || s.contains("authentication") {
                return .needsKey(stderr)
            }
            if s.contains("timed out") || s.contains("timeout") { return .timeout }
            // resolve failures, connection refused, no route, host key problems → unreachable
            return .unreachable(stderr)
        }
        return .commandFailed(code: exitCode, stderr: stderr)
    }
}

/// The SSH operations RemoteManager/RemoteSync need. A protocol (not the concrete struct) so the
/// SSH-driven paths - hook version-gate, settings merge, audit/session pull - can be unit-tested
/// with a fake that records commands and returns canned output, instead of only via the gated E2E.
public protocol SSHClient: Sendable {
    @discardableResult func run(host: String, command: String) throws -> String
    func runData(host: String, command: String) throws -> Data
    func upload(localPath: String, to host: String, remotePath: String) throws
    func download(from host: String, remotePath: String, to localPath: String) throws
}

extension SSHRunner: SSHClient {}

/// Shells out to the system `ssh`/`scp` by ABSOLUTE path so it works from a login-item GUI app
/// (which has a trimmed `PATH`). Always non-interactive: `BatchMode=yes` (never prompt for a
/// password - we only support key/agent/Tailscale auth) + an explicit `ConnectTimeout` so an
/// unreachable host fails fast instead of hanging the app. `-F` points at the user's own ssh
/// config so aliases, ControlMaster, jump hosts and agent forwarding all behave like VSCode's.
public struct SSHRunner: Sendable {
    public let sshPath: String
    public let scpPath: String
    public let configPath: String
    public let connectTimeout: Int

    public init(sshPath: String = "/usr/bin/ssh",
                scpPath: String = "/usr/bin/scp",
                configPath: String = ("~/.ssh/config" as NSString).expandingTildeInPath,
                connectTimeout: Int = 10) {
        self.sshPath = sshPath
        self.scpPath = scpPath
        self.configPath = configPath
        self.connectTimeout = connectTimeout
    }

    private var baseOptions: [String] {
        var opts: [String] = []
        if FileManager.default.fileExists(atPath: configPath) { opts += ["-F", configPath] }
        opts += ["-o", "BatchMode=yes", "-o", "ConnectTimeout=\(connectTimeout)"]
        return opts
    }

    /// Run a command on `host`, returning its stdout as text. Throws a `RemoteError` on any failure.
    @discardableResult
    public func run(host: String, command: String) throws -> String {
        String(decoding: try runData(host: host, command: command), as: UTF8.self)
    }

    /// Like `run`, but returns RAW stdout bytes. Use for incremental file pulls (`tail -c +N`):
    /// decoding to String could split a multibyte UTF-8 char at a byte boundary and corrupt the
    /// mirror; appending the raw Data is byte-exact and reassembles correctly across pulls.
    public func runData(host: String, command: String) throws -> Data {
        let args = baseOptions + [host, command]
        let r = try Self.exec(sshPath, args)
        if let err = RemoteError.classify(exitCode: r.code, stderr: r.stderr) { throw err }
        return r.stdout
    }

    /// scp a local file up to `host:remotePath`. `-p` preserves mode (so +x survives).
    public func upload(localPath: String, to host: String, remotePath: String) throws {
        let args = baseOptions + ["-p", localPath, "\(host):\(remotePath)"]
        let r = try Self.exec(scpPath, args)
        if let err = RemoteError.classify(exitCode: r.code, stderr: r.stderr) { throw err }
    }

    /// scp a remote file down to a local path.
    public func download(from host: String, remotePath: String, to localPath: String) throws {
        let args = baseOptions + ["\(host):\(remotePath)", localPath]
        let r = try Self.exec(scpPath, args)
        if let err = RemoteError.classify(exitCode: r.code, stderr: r.stderr) { throw err }
    }

    // MARK: Process plumbing

    struct ExecResult { let code: Int32; let stdout: Data; let stderr: String }

    static func exec(_ launchPath: String, _ args: [String]) throws -> ExecResult {
        guard FileManager.default.isExecutableFile(atPath: launchPath) else {
            throw RemoteError.localFailure("not executable: \(launchPath)")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { throw RemoteError.localFailure(error.localizedDescription) }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return ExecResult(
            code: p.terminationStatus,
            stdout: outData,
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }
}
