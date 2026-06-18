import XCTest
@testable import CompanionKit

final class SettingsInstallerTests: XCTestCase {
    private func tmpSettings(_ contents: String?) throws -> String {
        let dir = NSTemporaryDirectory() + "cc-settings-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/settings.json"
        if let contents { try contents.write(toFile: path, atomically: true, encoding: .utf8) }
        return path
    }

    private func load(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private let hookCmd = "/Applications/ClaudeCompanion.app/Contents/Helpers/companion-hook"

    func testInstallPreservesExistingRtkHook() throws {
        // Simulate the user's existing rtk Bash PreToolUse hook + an unrelated top-level key.
        let existing = """
        {"theme":"dark","hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"rtk hook claude"}]}]}}
        """
        let path = try tmpSettings(existing)
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        try SettingsInstaller(settingsPath: path, hookCommand: hookCmd).install()

        let json = try load(path)
        XCTAssertEqual(json["theme"] as? String, "dark")                  // unrelated key preserved
        let pre = try XCTUnwrap((json["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])
        let commands = pre.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }.compactMap { $0["command"] as? String }
        XCTAssertTrue(commands.contains("rtk hook claude"))               // rtk survives
        XCTAssertTrue(commands.contains(hookCmd))                         // ours added
        // and our other events were registered too
        XCTAssertNotNil((json["hooks"] as? [String: Any])?["Stop"])
    }

    func testInstallIsIdempotent() throws {
        let path = try tmpSettings(nil)
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let inst = SettingsInstaller(settingsPath: path, hookCommand: hookCmd)
        try inst.install(); try inst.install()
        let pre = try XCTUnwrap((try load(path)["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])
        let ours = pre.filter { g in ((g["hooks"] as? [[String: Any]]) ?? []).contains { ($0["command"] as? String) == self.hookCmd } }
        XCTAssertEqual(ours.count, 1) // no duplicates
    }

    func testUninstallRemovesOnlyOurs() throws {
        let existing = """
        {"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"rtk hook claude"}]}]}}
        """
        let path = try tmpSettings(existing)
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let inst = SettingsInstaller(settingsPath: path, hookCommand: hookCmd)
        try inst.install()
        XCTAssertTrue(inst.isInstalled())
        try inst.uninstall()
        XCTAssertFalse(inst.isInstalled())

        let pre = try XCTUnwrap((try load(path)["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])
        let commands = pre.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }.compactMap { $0["command"] as? String }
        XCTAssertEqual(commands, ["rtk hook claude"]) // rtk intact, ours gone
    }

    func testInstallIntoMissingFile() throws {
        let path = try tmpSettings(nil)
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let inst = SettingsInstaller(settingsPath: path, hookCommand: hookCmd)
        XCTAssertFalse(inst.isInstalled())
        try inst.install()
        XCTAssertTrue(inst.isInstalled())
    }
}
