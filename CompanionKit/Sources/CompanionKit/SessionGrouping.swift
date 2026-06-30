import Foundation

/// One project's active sessions collapsed into a single row (session-grouping.spec.md). A power
/// user runs many concurrent Claude Code sessions in the same folder; grouping them stops the list
/// reading like a duplication bug. Aggregates are sums across the member sessions.
public struct ProjectSessionGroup: Identifiable, Sendable, Equatable {
    public let id: String              // group key = project path (stable), or the name if no path
    public let projectName: String
    public let sessions: [SessionSummary]   // members, newest-first
    public let toolCount: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheTokens: Int
    public let costUSD: Double?         // sum of priced members (nil only if none are priced)
    public let models: [String]        // distinct models in use, newest-first
    public let recentTools: [String]   // from the newest member
    public let host: String            // from the newest member ("local" or an SSH alias)
    public let lastSeen: Date?         // latest activity in the group

    public var sessionCount: Int { sessions.count }
}

public enum SessionGrouping {
    /// The folder a session is *actually working in*, derived **only from the files it EDITS**
    /// (Claude Code records just the launch cwd, so a session started at a monorepo root but editing
    /// `repo/platform/vega/**` should read as "vega"). Deliberately conservative:
    ///  - edits only (reads are often incidental - opening docs across other repos);
    ///  - if **any** edit lands outside the launch dir, the session is "broad" → keep the cwd (don't
    ///    relabel it to one of the subfolders it happens to touch);
    ///  - otherwise return the deepest common ancestor of the edits, but only when it's strictly
    ///    deeper than the launch dir.
    /// Returns nil (→ caller uses the cwd) in every uncertain case. Pure - unit-tested.
    public static func workingDirectory(projectPath: String?, editPaths: [String]) -> String? {
        guard let root = projectPath, !root.isEmpty else { return nil }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        let dirs = editPaths.map { ($0 as NSString).deletingLastPathComponent }
        let underCwd = dirs.filter { $0 == root || $0.hasPrefix(prefix) }
        // A *real* edit outside the launch dir (not a scratch/config path) means this is a broad
        // session - keep the cwd rather than narrowing it to one subfolder it happens to touch.
        let realOutside = dirs.contains { $0 != root && !$0.hasPrefix(prefix) && !isTransient($0) }
        if realOutside { return nil }
        guard !underCwd.isEmpty else { return nil }
        let common = commonPathPrefix(underCwd)
        return common.count > root.count ? common : nil          // only when deeper than the root
    }

    /// Scratch / config / system locations that don't count as "working in another project".
    static func isTransient(_ dir: String) -> Bool {
        let home = NSHomeDirectory()
        let transient = ["/tmp", "/private/tmp", "/private/var", "/var", "/etc", "/usr",
                         home + "/Library", home + "/.claude", home + "/.config", home + "/.cache"]
        return transient.contains { dir == $0 || dir.hasPrefix($0 + "/") }
    }

    /// Longest shared leading path-component prefix across the given absolute paths.
    static func commonPathPrefix(_ paths: [String]) -> String {
        let split = paths.map { $0.split(separator: "/", omittingEmptySubsequences: false).map(String.init) }
        guard var common = split.first else { return "" }
        for comps in split.dropFirst() {
            var n = 0
            while n < common.count, n < comps.count, common[n] == comps[n] { n += 1 }
            common = Array(common.prefix(n))
        }
        return common.joined(separator: "/")
    }

    /// Collapse sessions sharing a working folder into one group. Keyed by `workingPath` (the
    /// derived subfolder) then `projectPath`, so two different folders never merge and a monorepo
    /// root splits by what each session actually works on. Members/groups ordered newest-first.
    public static func groupByProject(_ sessions: [SessionSummary]) -> [ProjectSessionGroup] {
        // Preserve first-seen key order, then sort the result; gives a deterministic grouping.
        var order: [String] = []
        var buckets: [String: [SessionSummary]] = [:]
        for s in sessions {
            let key = s.workingPath ?? s.projectPath ?? s.projectName
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(s)
        }

        let groups: [ProjectSessionGroup] = order.compactMap { key in
            guard let members = buckets[key], !members.isEmpty else { return nil }
            let sorted = members.sorted { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }
            let newest = sorted[0]

            let priced = sorted.compactMap(\.costUSD)
            let cost: Double? = priced.isEmpty ? nil : priced.reduce(0, +)

            // Distinct models, newest-first, nils dropped.
            var seenModel = Set<String>()
            let models = sorted.compactMap(\.model).filter { seenModel.insert($0).inserted }

            return ProjectSessionGroup(
                id: key,
                projectName: newest.projectName,
                sessions: sorted,
                toolCount: sorted.reduce(0) { $0 + $1.toolCount },
                inputTokens: sorted.reduce(0) { $0 + $1.inputTokens },
                outputTokens: sorted.reduce(0) { $0 + $1.outputTokens },
                cacheTokens: sorted.reduce(0) { $0 + $1.cacheTokens },
                costUSD: cost,
                models: models,
                recentTools: newest.recentTools,
                host: newest.host,
                lastSeen: newest.lastSeen
            )
        }

        return groups.sorted { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }
    }
}
