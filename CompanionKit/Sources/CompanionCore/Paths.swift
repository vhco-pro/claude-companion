import Foundation

/// Resolves Claude Companion's config-dir paths. Shared by the app and the hook so they always
/// agree. Honors `COMPANION_CONFIG_DIR` (explicit override, used in tests) then `XDG_CONFIG_HOME`,
/// falling back to ~/.config/claude-companion.
public enum Paths {
    public static var configDir: String {
        if let override = ProcessInfo.processInfo.environment["COMPANION_CONFIG_DIR"], !override.isEmpty {
            return override   // tests only
        }
        // Fixed, env-independent path. The app (writes rules) and the hook (reads them) run in
        // DIFFERENT environments (GUI app vs extension-launched hook); honoring XDG_CONFIG_HOME
        // made them disagree → hook couldn't find rules.compiled.json → fell back to "ask".
        // NSHomeDirectory() is getpwuid-based, immune to $HOME/$XDG quirks, so both always agree.
        return NSHomeDirectory() + "/.config/claude-companion"
    }

    public static var configFile: String { configDir + "/config.yaml" }
    public static var rulesFile: String { configDir + "/rules.yaml" }
    /// App-owned overrides (allow exceptions, custom deny/ask, disabled shipped rules). Merged with
    /// rules.yaml at compile time. The app only ever writes THIS file, never the shipped rules.yaml.
    public static var rulesLocalFile: String { configDir + "/rules.local.yaml" }
    public static var rulesCompiled: String { configDir + "/rules.compiled.json" }
    public static var blocklist: String { configDir + "/blocklist.db" }
    public static var auditLog: String { configDir + "/audit.ndjson" }
    public static var auditOffset: String { configDir + "/audit.offset" }
    public static var database: String { configDir + "/companion.db" }
}
