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
    /// Collapse sessions sharing a project into one group. Keyed by `projectPath` (so two different
    /// folders with the same leaf name stay separate); falls back to `projectName` when no path.
    /// Members and groups are ordered newest-active first. Pure - safe to unit test.
    public static func groupByProject(_ sessions: [SessionSummary]) -> [ProjectSessionGroup] {
        // Preserve first-seen key order, then sort the result; gives a deterministic grouping.
        var order: [String] = []
        var buckets: [String: [SessionSummary]] = [:]
        for s in sessions {
            let key = s.projectPath ?? s.projectName
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
