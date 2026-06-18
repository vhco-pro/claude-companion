import CompanionCore
import Foundation

/// Merges feed results into the sorted `host<TAB>class` file the hook reads. `malicious` beats
/// `compromised` on conflict; `allow_overrides` hosts are excluded entirely.
public enum BlocklistCompiler {
    @discardableResult
    public static func compile(entries: [(host: String, cls: DomainClass)],
                               overrides: Set<String>,
                               outPath: String) throws -> Int {
        var map: [String: DomainClass] = [:]
        for e in entries {
            let h = e.host.lowercased()
            if overrides.contains(h) { continue }
            if map[h] == .malicious { continue }          // malicious sticks
            if e.cls == .malicious { map[h] = .malicious }
            else if map[h] == nil { map[h] = .compromised }
        }
        let lines = map.keys.sorted().map { "\($0)\t\(map[$0]!.rawValue)" }
        let body = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        try body.write(toFile: outPath, atomically: true, encoding: .utf8)
        return map.count
    }
}
