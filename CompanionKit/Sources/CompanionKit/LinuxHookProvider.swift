import CompanionCore
import CryptoKit
import Foundation

/// Fetches the arch-matched Linux `companion-hook` for the running app version, verifies its
/// published SHA-256, and caches it under Application Support. Keeps the cask small - only users who
/// register a remote ever download the ~55 MB binary (see remote-ssh.spec.md, "download-on-demand").
public struct LinuxHookProvider: Sendable {
    public enum HookError: Error, Equatable, Sendable {
        case unsupportedArch(String)
        case download(String)
        case checksumMismatch(expected: String, got: String)
    }

    /// `owner/repo` whose Releases carry the `companion-hook-linux-<arch>` assets.
    public let repoSlug: String
    public let version: String
    private let session: URLSession

    public init(version: String = CompanionKit.version,
                repoSlug: String = "vhco-pro/claude-companion",
                session: URLSession = .shared) {
        self.version = version
        self.repoSlug = repoSlug
        self.session = session
    }

    /// Normalize `uname -m` to our asset arch token. Linux reports `x86_64` / `aarch64` (some
    /// distros say `arm64`); anything else is unsupported.
    public static func arch(forUname uname: String) -> String? {
        switch uname.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "x86_64", "amd64": return "x86_64"
        case "aarch64", "arm64": return "aarch64"
        default: return nil
        }
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A `<hash>  <filename>` .sha256 file (sha256sum format) carries the hash as its first field.
    static func expectedHash(fromSidecar text: String) -> String? {
        text.split(whereSeparator: \.isWhitespace).first.map { String($0).lowercased() }
    }

    private func assetURL(_ name: String) -> URL? {
        URL(string: "https://github.com/\(repoSlug)/releases/download/v\(version)/\(name)")
    }

    /// Return the cached hook for `arch`, downloading + verifying it on first use. The cache is
    /// keyed by version, so a new app version fetches a fresh binary (and the old one can be pruned).
    public func ensure(arch: String) async throws -> String {
        let cached = Paths.linuxHook(version: version, arch: arch)
        if FileManager.default.isExecutableFile(atPath: cached) { return cached }

        let assetName = "companion-hook-linux-\(arch)"
        guard let binURL = assetURL(assetName), let shaURL = assetURL(assetName + ".sha256") else {
            throw HookError.download("bad asset URL for \(assetName)")
        }
        let bin = try await fetch(binURL)
        let shaText = String(decoding: try await fetch(shaURL), as: UTF8.self)
        guard let expected = Self.expectedHash(fromSidecar: shaText) else {
            throw HookError.download("missing checksum for \(assetName)")
        }
        let got = Self.sha256Hex(bin)
        guard got == expected else { throw HookError.checksumMismatch(expected: expected, got: got) }

        try FileManager.default.createDirectory(
            atPath: (cached as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try bin.write(to: URL(fileURLWithPath: cached), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cached)
        return cached
    }

    private func fetch(_ url: URL) async throws -> Data {
        do {
            let (data, resp) = try await session.data(from: url)
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw HookError.download("HTTP \(http.statusCode) for \(url.lastPathComponent)")
            }
            return data
        } catch let e as HookError {
            throw e
        } catch {
            throw HookError.download(error.localizedDescription)
        }
    }
}
