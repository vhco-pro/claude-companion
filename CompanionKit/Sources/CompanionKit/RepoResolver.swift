import CompanionCore
import Foundation

/// Resolves a session's working directory to its repo web URL by reading the git remote.
/// Shells out to `git` (so it lives in the app library, not the dependency-free hook); callers
/// run it off the main thread and cache the result per directory - the spec wants no git call on
/// render. Returns nil for non-git dirs, repos with no remote, or unparseable remotes.
public enum RepoResolver {
    public static func webURL(forCwd cwd: String, timeout: TimeInterval = 3) -> URL? {
        guard let remote = remoteURL(cwd: cwd, timeout: timeout) else { return nil }
        return RepoURL.web(from: remote)
    }

    /// `remote.origin.url`, falling back to the first configured remote.
    static func remoteURL(cwd: String, timeout: TimeInterval) -> String? {
        if let origin = git(["-C", cwd, "config", "--get", "remote.origin.url"], timeout: timeout),
           !origin.isEmpty {
            return origin
        }
        if let first = git(["-C", cwd, "remote"], timeout: timeout)?
            .split(separator: "\n").first.map(String.init),
           let url = git(["-C", cwd, "config", "--get", "remote.\(first).url"], timeout: timeout),
           !url.isEmpty {
            return url
        }
        return nil
    }

    private static func git(_ args: [String], timeout: TimeInterval) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = args
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"        // never block on a credential prompt
        proc.environment = env

        do { try proc.run() } catch { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if proc.isRunning { proc.terminate() }   // watchdog: a hung git (slow mount) can't stall us
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()   // remote URLs are tiny; no deadlock
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
