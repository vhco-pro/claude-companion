import Foundation

/// Parses `~/.ssh/config` for concrete `Host` aliases - the same list VSCode Remote-SSH offers when
/// you "Connect to Host". Pure + string-based so it unit-tests without touching the filesystem.
///
/// We surface only *concrete* aliases the user can connect to: pattern entries (`Host *`,
/// `Host *.internal`, negations) are config defaults, not destinations, so they're skipped.
public enum SSHConfigParser {
    /// Concrete host aliases in file order, de-duplicated. Wildcard/negation patterns are dropped.
    public static func aliases(from text: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            // Strip comments + surrounding whitespace; tolerate `Key value` and `Key=value`.
            let line = rawLine.split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            // Match a leading "Host" keyword case-insensitively, then take the rest as patterns.
            let parts = trimmed.replacingOccurrences(of: "=", with: " ")
                .split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let key = parts.first, key.caseInsensitiveCompare("Host") == .orderedSame else { continue }
            for token in parts.dropFirst() {
                // Skip patterns - they're defaults, not connectable hosts.
                if token.contains("*") || token.contains("?") || token.hasPrefix("!") { continue }
                if seen.insert(token).inserted { out.append(token) }
            }
        }
        return out
    }

    /// Concrete aliases from the user's `~/.ssh/config` (empty if it's absent/unreadable).
    public static func aliases(configPath: String = ("~/.ssh/config" as NSString).expandingTildeInPath) -> [String] {
        guard let text = try? String(contentsOfFile: configPath, encoding: .utf8) else { return [] }
        return aliases(from: text)
    }
}
