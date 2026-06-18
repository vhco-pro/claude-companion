import CompanionCore
import Foundation
import Yams

public struct ModelPricing: Codable, Sendable, Equatable {
    public let input: Double        // USD per million tokens
    public let output: Double
    public let cacheRead: Double
    public let cacheWrite: Double
    enum CodingKeys: String, CodingKey { case input, output; case cacheRead = "cache_read"; case cacheWrite = "cache_write" }
}

/// Per-model pricing for cost estimates. Unknown models yield nil (we never fabricate a cost).
public struct PricingTable: Sendable {
    private let table: [String: ModelPricing]
    public init(table: [String: ModelPricing]) { self.table = table }

    public static func load(yaml: String) -> PricingTable? {
        guard let t = try? YAMLDecoder().decode([String: ModelPricing].self, from: yaml) else { return nil }
        return PricingTable(table: t)
    }

    public func pricing(for model: String?) -> ModelPricing? {
        guard let m = model else { return nil }
        if let p = table[m] { return p }
        // tolerate suffix variants like "claude-opus-4-8[1m]" by base-id prefix match
        return table.first { m.hasPrefix($0.key) }?.value
    }

    /// Cost in USD; nil if the model isn't priced.
    public func cost(model: String?, input: Int, output: Int, cacheRead: Int, cacheWrite: Int) -> Double? {
        guard let p = pricing(for: model) else { return nil }
        return (Double(input) * p.input + Double(output) * p.output
              + Double(cacheRead) * p.cacheRead + Double(cacheWrite) * p.cacheWrite) / 1_000_000
    }
}

/// Seeds the bundled default pricing.yaml on first run and loads it (falling back to the bundled
/// copy if the user file is missing/broken).
public final class PricingStore {
    public let path: String
    public init(path: String = Paths.configDir + "/pricing.yaml") { self.path = path }

    public func ensureDefault() {
        guard !FileManager.default.fileExists(atPath: path),
              let url = Bundle.module.url(forResource: "default-pricing", withExtension: "yaml"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    public func load() -> PricingTable {
        if let yaml = try? String(contentsOfFile: path, encoding: .utf8), let t = PricingTable.load(yaml: yaml) { return t }
        if let url = Bundle.module.url(forResource: "default-pricing", withExtension: "yaml"),
           let yaml = try? String(contentsOf: url, encoding: .utf8), let t = PricingTable.load(yaml: yaml) { return t }
        return PricingTable(table: [:])
    }
}
