import Foundation

/// Pulls domain-like hosts out of a Bash command so the blocklist can be checked. Intentionally
/// broad: matches any `label.label(.label…)` token (covering `curl https://evil.com/x`,
/// `wget evil.com`, `WebFetch` URLs, etc.). False hosts (e.g. `file.txt`) are harmless - they
/// simply won't be in the blocklist. IP literals are out of scope for v0.1 (last label must be
/// alphabetic).
public enum URLExtractor {
    private static let pattern = "(?:[A-Za-z0-9_-]+\\.)+[A-Za-z]{2,}"
    private static let regex = try? NSRegularExpression(pattern: pattern)

    public static func hosts(in command: String) -> [String] {
        guard let regex else { return [] }
        let range = NSRange(command.startIndex..., in: command)
        var out: [String] = []
        var seen = Set<String>()
        for m in regex.matches(in: command, range: range) {
            guard let r = Range(m.range, in: command) else { continue }
            let host = command[r].lowercased()
            if seen.insert(host).inserted { out.append(host) }
        }
        return out
    }
}
