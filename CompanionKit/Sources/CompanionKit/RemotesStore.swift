import CompanionCore
import Foundation
import Yams

/// A registered remote-SSH host (remote-ssh.spec.md). `alias` matches a `~/.ssh/config` Host entry.
/// A disabled remote stays listed but isn't synced.
public struct Remote: Codable, Sendable, Equatable, Identifiable {
    public var alias: String
    public var enabled: Bool
    public var id: String { alias }
    public init(alias: String, enabled: Bool = true) { self.alias = alias; self.enabled = enabled }
    enum CodingKeys: String, CodingKey { case alias, enabled }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        alias = try c.decode(String.self, forKey: .alias)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
    }
}

/// App-owned persistence of the registered-remotes list (`remotes.yaml`). The app round-trips this
/// freely (add/remove host), so it lives apart from the user's comment-bearing config.yaml.
public final class RemotesStore {
    private let path: String
    public init(path: String = Paths.remotesFile) { self.path = path }

    private struct File: Codable { var remotes: [Remote] }

    public func load() -> [Remote] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              let f = try? YAMLDecoder().decode(File.self, from: text) else { return [] }
        return f.remotes
    }

    public func save(_ remotes: [Remote]) throws {
        let text = try YAMLEncoder().encode(File(remotes: remotes))
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Add (or re-enable) a host; idempotent on alias.
    @discardableResult
    public func add(alias: String) throws -> [Remote] {
        var list = load()
        if let i = list.firstIndex(where: { $0.alias == alias }) { list[i].enabled = true }
        else { list.append(Remote(alias: alias)) }
        try save(list)
        return list
    }

    @discardableResult
    public func remove(alias: String) throws -> [Remote] {
        let list = load().filter { $0.alias != alias }
        try save(list)
        return list
    }
}

/// Per-host volatile sync status for the UI. App-owned sidecar, keyed by alias under remotes/.
/// Never hand-edited; safe to delete (a missing file = fresh sync). Pull progress is NOT stored
/// here - the local mirror file's size is the source of truth, so a deleted sidecar self-heals.
public struct RemoteState: Codable, Sendable, Equatable {
    public var lastSync: Date?
    public var lastError: String?
    public var reachable: Bool
    public var hookVersion: String?              // hook version last pushed to the host
    public var lastRemindedHookVersion: String?  // version we last nudged the user to reload for

    public init(lastSync: Date? = nil, lastError: String? = nil,
                reachable: Bool = false, hookVersion: String? = nil,
                lastRemindedHookVersion: String? = nil) {
        self.lastSync = lastSync
        self.lastError = lastError
        self.reachable = reachable
        self.hookVersion = hookVersion
        self.lastRemindedHookVersion = lastRemindedHookVersion
    }

    enum CodingKeys: String, CodingKey {
        case lastSync, lastError, reachable, hookVersion, lastRemindedHookVersion
    }
    public init(from d: Decoder) throws {   // tolerate old sidecars without the new key
        let c = try d.container(keyedBy: CodingKeys.self)
        lastSync = try c.decodeIfPresent(Date.self, forKey: .lastSync)
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        reachable = (try? c.decodeIfPresent(Bool.self, forKey: .reachable)) ?? false
        hookVersion = try c.decodeIfPresent(String.self, forKey: .hookVersion)
        lastRemindedHookVersion = try c.decodeIfPresent(String.self, forKey: .lastRemindedHookVersion)
    }

    /// Nudge the user to reload a host's VSCode window iff a NEW hook version was pushed (once per
    /// version, not every sync). Pure → unit-tested.
    public static func shouldRemindReload(hookVersion: String?, lastReminded: String?) -> Bool {
        guard let hv = hookVersion else { return false }
        return hv != lastReminded
    }
}

/// Load/save a host's `RemoteState` sidecar.
public final class RemoteStateStore {
    public init() {}

    public func load(alias: String) -> RemoteState {
        let p = Paths.remoteState(alias)
        guard let d = FileManager.default.contents(atPath: p),
              let s = try? JSONDecoder().decode(RemoteState.self, from: d) else { return RemoteState() }
        return s
    }

    public func save(alias: String, _ state: RemoteState) {
        try? FileManager.default.createDirectory(atPath: Paths.remotesDir, withIntermediateDirectories: true)
        guard let d = try? JSONEncoder().encode(state) else { return }
        try? d.write(to: URL(fileURLWithPath: Paths.remoteState(alias)), options: .atomic)
    }
}
