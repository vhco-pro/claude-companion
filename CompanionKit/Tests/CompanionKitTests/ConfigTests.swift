import XCTest
@testable import CompanionKit

final class ConfigTests: XCTestCase {
    private func tmpDir() throws -> String {
        let dir = NSTemporaryDirectory() + "cc-cfg-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    func testLoadsFullConfig() throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let p = dir + "/config.yaml"
        try "ui:\n  status_format: \"X {weekly}%\"\nlog_level: debug\n".write(toFile: p, atomically: true, encoding: .utf8)
        let c = try ConfigStore.load(p)
        XCTAssertEqual(c.ui.statusFormat, "X {weekly}%")
        XCTAssertEqual(c.logLevel, "debug")
    }

    func testPartialConfigFallsBackToDefaults() throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let p = dir + "/config.yaml"
        try "log_level: warn\n".write(toFile: p, atomically: true, encoding: .utf8) // no `ui:`
        let c = try ConfigStore.load(p)
        XCTAssertEqual(c.logLevel, "warn")
        XCTAssertEqual(c.ui.statusFormat, AppConfig.default.ui.statusFormat) // default-filled
    }

    func testReloadKeepsLastGoodOnMalformedYAML() throws {
        let dir = try tmpDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let p = dir + "/config.yaml"
        try "log_level: info\n".write(toFile: p, atomically: true, encoding: .utf8)
        let store = ConfigStore(path: p)
        XCTAssertEqual(store.config.logLevel, "info")

        try "log_level: [unclosed bracket\n".write(toFile: p, atomically: true, encoding: .utf8) // YAML syntax error
        XCTAssertFalse(store.reload())                 // parse fails → keep last-good
        XCTAssertEqual(store.config.logLevel, "info")  // unchanged
    }
}
