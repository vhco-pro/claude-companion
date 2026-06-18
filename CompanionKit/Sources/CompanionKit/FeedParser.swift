import CompanionCore
import Foundation

/// Parses threat-feed bodies into hosts. Pure (no network) so it's unit-testable. Three formats:
///  - "hosts":   /etc/hosts style - `0.0.0.0 evil.com` / `127.0.0.1 evil.com`
///  - "domains": one domain per line
///  - "urls":    one URL per line (host extracted)
public enum FeedParser {
    public static func parse(_ text: String, format: String) -> [String] {
        var hosts: [String] = []
        for raw in text.components(separatedBy: .newlines) {  // tolerate \n, \r, \r\n
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("!") { continue }
            switch format {
            case "hosts":
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                    .flatMap { $0.split(separator: "\t") }
                guard parts.count >= 2 else { continue }
                let host = String(parts[1]).lowercased()
                if isValidHost(host) { hosts.append(host) }
            case "domains":
                let host = line.lowercased()
                if isValidHost(host) { hosts.append(host) }
            case "urls":
                // Parse the real URL host (not path tokens). Tolerate scheme-less lines.
                let candidate = line.contains("://") ? line : "http://" + line
                if let host = URL(string: candidate)?.host?.lowercased(), isValidHost(host) {
                    hosts.append(host)
                }
            default:
                continue
            }
        }
        return hosts
    }

    private static func isValidHost(_ h: String) -> Bool {
        guard h.contains("."), !h.hasPrefix("."), !h.hasSuffix(".") else { return false }
        // skip localhost-ish noise common in hosts files
        if h == "localhost" || h == "local" || h == "broadcasthost" || h == "0.0.0.0" { return false }
        return true
    }
}
