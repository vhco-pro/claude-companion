import Foundation

/// Parsed response of GET api/oauth/usage (shape confirmed by live probe 2026-06-15). Every
/// field optional - the API is unpublished, so decode defensively and render only what's present.
public struct UsageSnapshot: Codable, Sendable, Equatable {
    public struct Bucket: Codable, Sendable, Equatable {
        public let utilization: Double?
        public let resetsAt: String?
        enum CodingKeys: String, CodingKey { case utilization; case resetsAt = "resets_at" }
    }
    public let fiveHour: Bucket?
    public let sevenDay: Bucket?
    public let sevenDayOpus: Bucket?
    public let sevenDaySonnet: Bucket?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
    }
}

/// Fetches the usage gauges using the existing Claude Code OAuth token. Never writes credentials.
public final class UsageClient {
    public enum Failure: Error, Equatable { case noToken, http(Int), decode, transport }

    private let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    public init() {}

    public func fetch() async -> Result<UsageSnapshot, Failure> {
        guard let token = KeychainReader.claudeOAuth()?.accessToken else { return .failure(.noToken) }
        var req = URLRequest(url: endpoint)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.timeoutInterval = 20
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return .failure(.http(http.statusCode))
            }
            guard let snap = try? JSONDecoder().decode(UsageSnapshot.self, from: data) else {
                return .failure(.decode)
            }
            return .success(snap)
        } catch {
            return .failure(.transport)
        }
    }
}
