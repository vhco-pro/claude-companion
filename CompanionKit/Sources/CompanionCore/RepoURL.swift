import Foundation

/// Pure git-remote → web-URL normalizer. Maps any remote form (SSH scp-like, ssh://, https,
/// with or without embedded credentials, with or without a trailing `.git`) to the canonical
/// https page for GitHub / GitLab / Bitbucket / Azure DevOps / self-hosted hosts. Returns nil
/// when the input doesn't parse - never a guessed or broken URL. Dependency-free (Foundation
/// only) so the app and a future remote-host sync can both reuse it.
public enum RepoURL {
    /// Convert a raw `remote.origin.url` value into the repo's web URL, or nil if unparseable.
    public static func web(from raw: String) -> URL? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        var host: String
        var path: String

        if let scheme = s.range(of: "://") {
            // scheme://[user@]host[:port]/path
            let rest = String(s[scheme.upperBound...])
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            host = stripUser(String(rest[..<slash]))
            path = String(rest[rest.index(after: slash)...])
        } else if let colon = s.firstIndex(of: ":"), !s[..<colon].contains("/") {
            // scp-like: [user@]host:path  (no scheme; host has no slash before the colon)
            host = stripUser(String(s[..<colon]))
            path = String(s[s.index(after: colon)...])
        } else {
            return nil
        }

        if let port = host.firstIndex(of: ":") { host = String(host[..<port]) }
        host = host.lowercased()
        guard !host.isEmpty else { return nil }

        path = trimSlashes(path)
        if path.hasSuffix(".git") { path = String(path.dropLast(4)) }
        path = trimSlashes(path)
        guard !path.isEmpty else { return nil }

        if host == "dev.azure.com" || host == "ssh.dev.azure.com" || host.hasSuffix(".visualstudio.com") {
            return azure(host: host, path: path)
        }
        return URL(string: "https://\(host)/\(path)")
    }

    /// Azure DevOps is the irregular one: the SSH path is `v3/{org}/{project}/{repo}` while the
    /// web/https path is `{org}/{project}/_git/{repo}`. Normalize both to the web form.
    private static func azure(host: String, path: String) -> URL? {
        var segs = path.split(separator: "/").map(String.init)
        if segs.first == "v3" { segs.removeFirst() }            // strip the SSH scp-form prefix
        if !segs.contains("_git"), segs.count >= 2 {
            segs.insert("_git", at: segs.count - 1)             // {…}/{repo} → {…}/_git/{repo}
        }
        // Legacy {org}.visualstudio.com keeps its host; modern Azure canonicalizes to dev.azure.com.
        let webHost = host.hasSuffix(".visualstudio.com") ? host : "dev.azure.com"
        return URL(string: "https://\(webHost)/\(segs.joined(separator: "/"))")
    }

    private static func stripUser(_ authority: String) -> String {
        guard let at = authority.lastIndex(of: "@") else { return authority }
        return String(authority[authority.index(after: at)...])
    }

    private static func trimSlashes(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
