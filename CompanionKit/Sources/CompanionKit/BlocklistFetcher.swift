import CompanionCore
import Foundation

/// Downloads the configured threat feeds, parses them, and compiles `blocklist.db`. On total
/// failure it leaves the existing file untouched (the hook keeps using the last-good blocklist).
public final class BlocklistFetcher: Sendable {   // no stored state -> safe to share across actors
    public init() {}

    public func refresh(config: BlocklistConfig, outPath: String = Paths.blocklist) async -> (count: Int, errors: [String]) {
        guard config.enabled else { return (0, []) }
        var entries: [(host: String, cls: DomainClass)] = []
        var errors: [String] = []

        for feed in config.feeds {
            guard let url = URL(string: feed.url) else { errors.append("\(feed.name): bad url"); continue }
            do {
                var request = URLRequest(url: url)
                // Some feeds (abuse.ch) serve a challenge/empty body to the default URLSession UA.
                request.setValue("ClaudeCompanion/0.1 (+https://github.com/vhco-pro/claude-companion)",
                                 forHTTPHeaderField: "User-Agent")
                // Force uncompressed - abuse.ch's gzip response mangled line endings under
                // URLSession's auto-decompression. identity gives us the raw text file.
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                request.timeoutInterval = 30
                let (data, resp) = try await URLSession.shared.data(for: request)
                if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    errors.append("\(feed.name): HTTP \(http.statusCode)"); continue
                }
                let cls = DomainClass(rawValue: feed.cls) ?? .malicious
                let hosts = FeedParser.parse(String(decoding: data, as: UTF8.self), format: feed.format)
                entries.append(contentsOf: hosts.map { ($0, cls) })
            } catch {
                errors.append("\(feed.name): \(error.localizedDescription)")
            }
        }

        guard !entries.isEmpty else { return (0, errors) }  // keep old file on total failure
        let overrides = Set(config.allowOverrides.map { $0.lowercased() })
        let count = (try? BlocklistCompiler.compile(entries: entries, overrides: overrides, outPath: outPath)) ?? 0
        return (count, errors)
    }
}
