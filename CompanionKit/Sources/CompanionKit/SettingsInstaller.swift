import Foundation

/// Installs/removes Claude Companion's hook entries in ~/.claude/settings.json. Merge-tagged:
/// our entries coexist with any existing hooks (e.g. the user's `rtk` Bash hook) and uninstall
/// removes only ours. Our entries are identified by the embedded companion-hook path (the tag).
public final class SettingsInstaller {
    public let settingsPath: String
    public let hookCommand: String
    private let events = ["PreToolUse", "PostToolUse", "SessionStart", "Stop"]
    private let marker = "companion-hook"          // identifies our hook by binary name (path-agnostic)
    private let rtkCommand = "rtk hook claude"

    public init(settingsPath: String = ("~/.claude/settings.json" as NSString).expandingTildeInPath,
                hookCommand: String) {
        self.settingsPath = settingsPath
        self.hookCommand = hookCommand
    }

    // MARK: JSON IO

    private func loadJSON() -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: settingsPath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    private func writeJSON(_ json: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        let dir = (settingsPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
    }

    private func isOurs(_ group: [String: Any]) -> Bool {
        guard let hooks = group["hooks"] as? [[String: Any]] else { return false }
        return hooks.contains { ($0["command"] as? String)?.contains(marker) == true }
    }

    private func ourGroup() -> [String: Any] {
        ["matcher": "*", "hooks": [["type": "command", "command": hookCommand]]]
    }

    private func isRTK(_ group: [String: Any]) -> Bool {
        guard let hooks = group["hooks"] as? [[String: Any]] else { return false }
        return hooks.contains { ($0["command"] as? String)?.contains("rtk hook") == true }
    }

    private func rtkGroup() -> [String: Any] {
        ["matcher": "Bash", "hooks": [["type": "command", "command": rtkCommand]]]
    }

    // MARK: API

    public func isInstalled() -> Bool {
        guard let hooks = loadJSON()["hooks"] as? [String: Any] else { return false }
        return events.contains { event in
            (hooks[event] as? [[String: Any]])?.contains(where: isOurs) == true
        }
    }

    /// Add our entries to each event array, preserving any existing entries; de-dupes ours.
    /// When `registerRTK` is true, also ensures rtk's own command-rewrite hook is present
    /// (Option A - reproducibility; rtk isn't bundled, just wired). Both hooks coexist.
    public func install(registerRTK: Bool = false) throws {
        var json = loadJSON()
        var hooks = json["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var arr = hooks[event] as? [[String: Any]] ?? []
            arr.removeAll(where: isOurs)
            arr.append(ourGroup())
            hooks[event] = arr
        }
        if registerRTK {
            var pre = hooks["PreToolUse"] as? [[String: Any]] ?? []
            if !pre.contains(where: isRTK) { pre.append(rtkGroup()) }
            hooks["PreToolUse"] = pre
        }
        json["hooks"] = hooks
        try writeJSON(json)
    }

    /// Remove only our entries; leave everyone else's hooks intact.
    public func uninstall() throws {
        var json = loadJSON()
        guard var hooks = json["hooks"] as? [String: Any] else { return }
        for event in events {
            guard var arr = hooks[event] as? [[String: Any]] else { continue }
            arr.removeAll(where: isOurs)
            if arr.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = arr }
        }
        if hooks.isEmpty { json.removeValue(forKey: "hooks") } else { json["hooks"] = hooks }
        try writeJSON(json)
    }
}
