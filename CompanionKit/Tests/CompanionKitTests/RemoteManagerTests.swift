import XCTest
import CompanionCore
@testable import CompanionKit

final class RemoteManagerTests: XCTestCase {

    // MARK: SSHConfigParser

    func testParsesConcreteAliasesAndSkipsPatterns() {
        let cfg = """
        # global defaults
        Host *
          ServerAliveInterval 60

        Host fedora
          HostName 100.64.0.1
          User m

        Host build-box jump.example
          User ci

        Host *.internal
          User svc

        Host !secret prod
          User ops
        """
        // Concrete aliases only, in order; wildcards (*, *.internal) and negation (!secret) dropped.
        XCTAssertEqual(SSHConfigParser.aliases(from: cfg), ["fedora", "build-box", "jump.example", "prod"])
    }

    func testParsesEqualsSyntaxAndCaseInsensitiveKeyword() {
        XCTAssertEqual(SSHConfigParser.aliases(from: "HOST=foo\nhost bar"), ["foo", "bar"])
    }

    func testEmptyConfigYieldsNoAliases() {
        XCTAssertEqual(SSHConfigParser.aliases(from: "\n# just a comment\n"), [])
    }

    // MARK: RemoteError.classify

    func testClassifyDistinguishesAuthFromUnreachable() {
        XCTAssertEqual(RemoteError.classify(exitCode: 255, stderr: "Permission denied (publickey)."),
                       .needsKey("Permission denied (publickey)."))
        XCTAssertEqual(RemoteError.classify(exitCode: 255, stderr: "ssh: connect to host x port 22: Connection refused"),
                       .unreachable("ssh: connect to host x port 22: Connection refused"))
        XCTAssertEqual(RemoteError.classify(exitCode: 255, stderr: "Operation timed out"), .timeout)
        XCTAssertEqual(RemoteError.classify(exitCode: 1, stderr: "no such file"),
                       .commandFailed(code: 1, stderr: "no such file"))
        XCTAssertNil(RemoteError.classify(exitCode: 0, stderr: ""))
    }

    // MARK: LinuxHookProvider pure helpers

    func testArchMapping() {
        XCTAssertEqual(LinuxHookProvider.arch(forUname: "x86_64\n"), "x86_64")
        XCTAssertEqual(LinuxHookProvider.arch(forUname: "aarch64"), "aarch64")
        XCTAssertEqual(LinuxHookProvider.arch(forUname: "arm64"), "aarch64")
        XCTAssertNil(LinuxHookProvider.arch(forUname: "riscv64"))
    }

    func testExpectedHashParsesSha256sumFormat() {
        let sidecar = "deadbeef0123  companion-hook-linux-x86_64\n"
        XCTAssertEqual(LinuxHookProvider.expectedHash(fromSidecar: sidecar), "deadbeef0123")
    }

    // MARK: RemotePaths layout

    func testRemotePathsLayoutAndTrailingSlash() {
        let rp = RemotePaths(home: "/home/m/")          // trailing slash normalized away
        XCTAssertEqual(rp.configDir, "/home/m/.config/claude-companion")
        XCTAssertEqual(rp.hook, "/home/m/.config/claude-companion/companion-hook")
        XCTAssertEqual(rp.settings, "/home/m/.claude/settings.json")
        XCTAssertEqual(rp.settingsBackup, "/home/m/.claude/settings.json.companion-bak")
    }

    func testSanitizeAliasKeepsSafeCharsAndNeutralizesTraversal() {
        XCTAssertEqual(Paths.sanitizeAlias("build-box.1"), "build-box.1")
        XCTAssertEqual(Paths.sanitizeAlias("../etc/passwd"), ".._etc_passwd")
    }

    func testShellQuotingEscapesSingleQuotes() {
        let rm = RemoteManager()
        XCTAssertEqual(rm.sh("/home/m/dir"), "'/home/m/dir'")
        XCTAssertEqual(rm.sh("a'b"), "'a'\\''b'")
    }

    // MARK: SettingsInstaller against a remote-style temp file (pull-merge-push core)

    func testRemoteSettingsMergePreservesUnknownKeys() throws {
        let dir = NSTemporaryDirectory() + "cc-rs-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/settings.json"
        // A realistic remote settings.json: other top-level keys, no `hooks`.
        try #"{"effortLevel":"high","enabledPlugins":["x"],"permissions":{"allow":["*"]}}"#
            .write(toFile: path, atomically: true, encoding: .utf8)

        let remoteHook = "/home/m/.config/claude-companion/companion-hook"
        let installer = SettingsInstaller(settingsPath: path, hookCommand: remoteHook)
        try installer.install()
        XCTAssertTrue(installer.isInstalled())

        let merged = try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
        XCTAssertEqual(merged["effortLevel"] as? String, "high")          // preserved
        XCTAssertNotNil(merged["enabledPlugins"])                          // preserved
        XCTAssertNotNil(merged["hooks"])                                   // added
        // The merged hooks must carry our REMOTE hook path (assert on the structure, not a
        // re-serialized blob - JSON escaping of '/' would make a substring check brittle).
        let hooks = merged["hooks"] as! [String: Any]
        let preCmds = (hooks["PreToolUse"] as! [[String: Any]])
            .compactMap { ($0["hooks"] as? [[String: Any]]) }.flatMap { $0 }
            .compactMap { $0["command"] as? String }
        XCTAssertTrue(preCmds.contains(remoteHook))                        // our REMOTE path tagged

        try installer.uninstall()
        XCTAssertFalse(installer.isInstalled())
        let after = try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
        XCTAssertEqual(after["effortLevel"] as? String, "high")           // still preserved post-uninstall
    }

    // MARK: LinuxHookProvider download + checksum verification (mocked network, offline)

    func testEnsureVerifiesChecksumAndCaches() async throws {
        let dir = NSTemporaryDirectory() + "cc-lh-\(UUID().uuidString)"
        setenv("COMPANION_CONFIG_DIR", dir, 1)
        defer { unsetenv("COMPANION_CONFIG_DIR"); try? FileManager.default.removeItem(atPath: dir) }

        let payload = Data("fake-linux-hook-binary".utf8)
        let good = LinuxHookProvider.sha256Hex(payload)
        let base = "https://github.com/test/repo/releases/download/v9.9.9/companion-hook-linux-x86_64"
        MockURLProtocol.responses = [
            base: (payload, 200),
            base + ".sha256": (Data("\(good)  companion-hook-linux-x86_64\n".utf8), 200),
        ]
        let session = MockURLProtocol.session()
        let provider = LinuxHookProvider(version: "9.9.9", repoSlug: "test/repo", session: session)

        let path = try await provider.ensure(arch: "x86_64")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), payload)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path))
        // Second call hits the cache (no network needed) and returns the same path.
        MockURLProtocol.responses = [:]
        let again = try await provider.ensure(arch: "x86_64")
        XCTAssertEqual(again, path)
    }

    func testEnsureRejectsTamperedBinary() async throws {
        let dir = NSTemporaryDirectory() + "cc-lh-\(UUID().uuidString)"
        setenv("COMPANION_CONFIG_DIR", dir, 1)
        defer { unsetenv("COMPANION_CONFIG_DIR"); try? FileManager.default.removeItem(atPath: dir) }

        let base = "https://github.com/test/repo/releases/download/v9.9.9/companion-hook-linux-aarch64"
        MockURLProtocol.responses = [
            base: (Data("tampered".utf8), 200),
            base + ".sha256": (Data("0000notthehash  companion-hook-linux-aarch64\n".utf8), 200),
        ]
        let provider = LinuxHookProvider(version: "9.9.9", repoSlug: "test/repo",
                                         session: MockURLProtocol.session())
        do {
            _ = try await provider.ensure(arch: "aarch64")
            XCTFail("expected checksum mismatch")
        } catch let LinuxHookProvider.HookError.checksumMismatch(expected, _) {
            XCTAssertEqual(expected, "0000notthehash")
        }
    }
}

/// Minimal URLProtocol stub so the download+verify path is testable offline.
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responses: [String: (Data, Int)] = [:]

    static func session() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: cfg)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let key = request.url?.absoluteString ?? ""
        if let (data, code) = Self.responses[key] {
            let resp = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
        } else {
            let resp = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
