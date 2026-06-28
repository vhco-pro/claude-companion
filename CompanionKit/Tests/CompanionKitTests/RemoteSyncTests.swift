import XCTest
import CompanionCore
@testable import CompanionKit

final class RemoteSyncTests: XCTestCase {

    // MARK: RemotesStore (app-owned remotes.yaml)

    func testRemotesStoreAddRemoveRoundTrip() throws {
        let dir = NSTemporaryDirectory() + "cc-rs-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = RemotesStore(path: dir + "/remotes.yaml")

        XCTAssertEqual(store.load(), [])
        _ = try store.add(alias: "fedora")
        _ = try store.add(alias: "build-box")
        XCTAssertEqual(store.load().map(\.alias), ["fedora", "build-box"])
        XCTAssertTrue(store.load().allSatisfy(\.enabled))            // default enabled

        _ = try store.add(alias: "fedora")                          // idempotent on alias
        XCTAssertEqual(store.load().count, 2)

        _ = try store.remove(alias: "fedora")
        XCTAssertEqual(store.load().map(\.alias), ["build-box"])
    }

    func testRemotesYamlDecodesEnabledDefault() throws {
        let dir = NSTemporaryDirectory() + "cc-ry-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/remotes.yaml"
        // Hand-written: one with explicit enabled:false, one omitting it (→ true).
        try "remotes:\n  - alias: a\n    enabled: false\n  - alias: b\n".write(toFile: path, atomically: true, encoding: .utf8)
        let store = RemotesStore(path: path)
        XCTAssertEqual(store.load(), [Remote(alias: "a", enabled: false), Remote(alias: "b", enabled: true)])
    }

    // MARK: RemoteStateStore sidecar

    func testRemoteStateRoundTripAndMissingDefault() {
        let dir = NSTemporaryDirectory() + "cc-st-\(UUID().uuidString)"
        setenv("COMPANION_CONFIG_DIR", dir, 1)
        defer { unsetenv("COMPANION_CONFIG_DIR"); try? FileManager.default.removeItem(atPath: dir) }
        let store = RemoteStateStore()

        XCTAssertEqual(store.load(alias: "ghost"), RemoteState())   // missing = fresh default
        let s = RemoteState(lastSync: nil, lastError: "boom", reachable: true, hookVersion: "1.2.3")
        store.save(alias: "fedora", s)
        XCTAssertEqual(store.load(alias: "fedora"), s)
    }

    // MARK: byte-exact mirror append (multibyte split safety)

    func testAppendIsByteExactAcrossMultibyteSplit() throws {
        let dir = NSTemporaryDirectory() + "cc-ap-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/mirror.ndjson"

        // A line whose emoji (4-byte UTF-8) we deliberately split across two "pulls".
        let full = Data("{\"cmd\":\"echo 🚀\"}\n".utf8)
        let cut = full.count - 3                                    // mid-emoji byte boundary
        XCTAssertEqual(RemoteSync.fileSize(path), 0)                // missing file
        try RemoteSync.append(full.prefix(cut), to: path)
        try RemoteSync.append(full.suffix(from: cut), to: path)

        let onDisk = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertEqual(onDisk, full)                                // reassembled byte-for-byte
        XCTAssertEqual(RemoteSync.fileSize(path), UInt64(full.count))
        XCTAssertEqual(String(decoding: onDisk, as: UTF8.self), "{\"cmd\":\"echo 🚀\"}\n")
    }
}
