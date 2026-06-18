import Foundation

public enum DomainClass: String, Sendable {
    case malicious     // dedicated-bad domain → deny
    case compromised   // normally-reputable but currently flagged → ask
}

/// Cached threat-feed domains the hook checks URLs against. Compiled by the app from feeds into
/// `blocklist.db` (one `host<TAB>class` line per entry). The hook loads it only when a command
/// actually references a host, keeping the common (no-URL) case free.
public struct Blocklist: Sendable {
    private let entries: [String: DomainClass]

    public init(entries: [String: DomainClass]) { self.entries = entries }

    public var count: Int { entries.count }

    /// Load from the compiled `host<TAB>class` file. Returns nil if absent/unreadable.
    public static func load(path: String) -> Blocklist? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var map: [String: DomainClass] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard let host = parts.first.map(String.init) else { continue }
            let cls = parts.count > 1 ? DomainClass(rawValue: String(parts[1])) : .malicious
            map[host.lowercased()] = cls ?? .malicious
        }
        return Blocklist(entries: map)
    }

    /// Match the host or any registrable parent (sub.evil.com → evil.com), down to 2 labels.
    public func lookup(_ host: String) -> DomainClass? {
        let h = host.lowercased()
        if let c = entries[h] { return c }
        let labels = h.split(separator: ".")
        guard labels.count > 2 else { return nil }
        for i in 1..<(labels.count - 1) {
            let parent = labels[i...].joined(separator: ".")
            if let c = entries[parent] { return c }
        }
        return nil
    }
}
