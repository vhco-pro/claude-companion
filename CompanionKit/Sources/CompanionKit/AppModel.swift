import AppKit
import CompanionCore
import Foundation
import GRDB
import Network
import Observation

/// The running app's in-process state. Wires the SQLite store, audit ingestor, config
/// hot-reload, and rules compilation together. SwiftUI observes it. There is no daemon: this
/// object IS the long-lived process.
@MainActor
@Observable
public final class AppModel {
    public private(set) var config: AppConfig
    /// Recent *actionable* decisions (ask/deny/compromised) only - routine `allow`s are the 99%
    /// and aren't actionable, so they'd bury the rows a user can do something about.
    public private(set) var recentDecisions: [AuditRecord] = []
    public private(set) var attentionCount: Int = 0
    public private(set) var totalDecisions: Int = 0
    public private(set) var autoAccept: Bool = true
    public private(set) var ruleWarnings: [String] = []
    public private(set) var hookInstalled: Bool = false
    public private(set) var blocklistCount: Int = 0
    public private(set) var blocklistUpdatedAt: Date?
    public private(set) var blocklistErrors: [String] = []
    public private(set) var blocklistEntries: [BlocklistEntry] = []
    public private(set) var sessions: [SessionSummary] = []

    public struct BlocklistEntry: Identifiable, Sendable {
        public let host: String
        public let malicious: Bool          // false = compromised
        public var id: String { host }
        public var classLabel: String { malicious ? "malicious" : "compromised" }
    }
    public private(set) var usage: UsageSnapshot?
    public private(set) var usageError: String?
    public private(set) var usageSignedOut: Bool = false   // true only when there's no token
    public private(set) var status: String = "starting…"

    /// Menu-bar SF Symbol (filled = auto-accept on). Used in the bar + the panel header.
    public var menuBarIcon: String { autoAccept ? "bolt.shield.fill" : "bolt.shield" }

    /// Menu-bar text: just the two percentages, e.g. "30% · 15%" (weekly · 5h).
    public var statusText: String {
        guard let u = usage else { return usageSignedOut ? "sign in" : "—" }
        func pct(_ b: UsageSnapshot.Bucket?) -> String {
            b?.utilization.map { "\(Int($0.rounded()))%" } ?? "—"
        }
        return "\(pct(u.sevenDay)) · \(pct(u.fiveHour))"
    }

    public static func fmtTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fK", Double(n) / 1_000) }
        return "\(n)"
    }

    /// Stale if the last successful refresh is older than 2× the refresh interval.
    public var blocklistStale: Bool {
        guard let at = blocklistUpdatedAt else { return false }
        return Date().timeIntervalSince(at) > Double(max(5, config.blocklist.refreshMinutes) * 60 * 2)
    }

    /// Menu summary line, e.g. "Blocklist: 552 domains · updated 2h ago" (+ "⚠️ stale").
    public var blocklistSummary: String {
        guard config.blocklist.enabled else { return "Blocklist: off" }
        guard blocklistCount > 0 else { return "Blocklist: building…" }
        var s = "Blocklist: \(blocklistCount) domains"
        if let at = blocklistUpdatedAt { s += " · updated \(Self.relative(at))" }
        if blocklistStale { s += " ⚠️ stale" }
        return s
    }

    public static func relative(_ date: Date) -> String {
        let secs = Int(Date().timeIntervalSince(date))
        if secs < 60 { return "just now" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        if secs < 86400 { return "\(secs / 3600)h ago" }
        return "\(secs / 86400)d ago"
    }

    private var db: AppDatabase?
    private var ingestor: AuditIngestor?
    private var sessionIngestor: SessionIngestor?
    private var tailer: JSONLTailer?
    private let pricingStore = PricingStore()
    private var pricing = PricingTable(table: [:])
    private let configStore: ConfigStore
    private let rules: RulesManager
    private var watcher: FileWatcher?
    private var hotkey: GlobalHotkey?
    private let fetcher = BlocklistFetcher()
    private var blocklistTimer: Timer?
    private let netMonitor = NWPathMonitor()
    private var wasOffline = false
    private let denyNotifier = DenyNotifier()
    /// Highest audit id already considered for a deny notification. Initialized to the current max
    /// on launch so the historical backlog isn't replayed as a burst of notifications.
    private var lastNotifiedAuditId: Int64 = 0
    private var usageTimer: Timer?
    private var lastRulesHash: Int = 0
    /// cwd → resolved repo web URL (nil = resolved, no repo). Presence of the key = already
    /// attempted, so we shell `git` at most once per directory.
    private var repoURLCache: [String: URL?] = [:]

    public init() {
        try? FileManager.default.createDirectory(atPath: Paths.configDir, withIntermediateDirectories: true)
        configStore = ConfigStore()
        config = configStore.config
        rules = RulesManager()
        do {
            let database = try AppDatabase.open()
            db = database
            ingestor = AuditIngestor(db: database)
            sessionIngestor = SessionIngestor(db: database)
            status = "ready"
        } catch {
            status = "db error: \(error.localizedDescription)"
        }
        rules.ensureDefaultRules()       // seed the bundled default blacklist on first run
        compileRules(force: true)        // rules.yaml → rules.compiled.json for the hook
        pricingStore.ensureDefault()
        pricing = pricingStore.load()
    }

    public struct ProjectCost: Identifiable, Sendable { public let id: String; public let cost: Double }

    /// Per-project cost rollup (priced sessions only), highest first.
    public var projectCosts: [ProjectCost] {
        var map: [String: Double] = [:]
        for s in sessions { if let c = s.costUSD { map[s.projectName, default: 0] += c } }
        return map.sorted { $0.value > $1.value }.map { ProjectCost(id: $0.key, cost: $0.value) }
    }

    /// Begin watching the config dir (audit.ndjson + config/rules) and do an initial load.
    public func start() {
        refresh()
        // Mark everything already logged as "seen" so launch doesn't replay old denies, then ask
        // for notification permission. New denies arriving via the file-watcher get notified.
        lastNotifiedAuditId = currentMaxAuditId()
        denyNotifier.requestAuth()
        refreshInstallState()
        if let si = sessionIngestor {
            refreshSessions()
            tailer = JSONLTailer(ingestor: si, onUpdate: { [weak self] in self?.refreshSessions() })
            tailer?.start()
        }

        usage = loadUsage()   // last-good across relaunches so the bars don't blank on a 429
        refreshUsageNow()
        // These callbacks fire off the main actor (timers, file-watch, hot-key, wake/network);
        // AppModel is @MainActor, so each hops back to the main actor before touching state.
        usageTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshUsageNow() }
        }
        watcher = FileWatcher(paths: [Paths.configDir]) { [weak self] in
            Task { @MainActor in self?.onConfigDirChanged() }
        }
        watcher?.start()
        hotkey = GlobalHotkey { [weak self] in
            Task { @MainActor in self?.toggleAutoAccept() }
        }
        hotkey?.register() // ⌃⌥⌘A

        if config.blocklist.enabled {
            blocklistCount = (Blocklist.load(path: Paths.blocklist))?.count ?? 0   // last-good
            blocklistUpdatedAt = fileModified(Paths.blocklist)
            loadBlocklistEntries()
            refreshBlocklistNow()
            let minutes = max(5, config.blocklist.refreshMinutes)
            blocklistTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshBlocklistNow() }
            }
            // Re-fetch on wake-from-sleep and when the network comes back, so a closed laptop
            // doesn't sit on a stale list for up to a full interval.
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in Task { @MainActor in self?.refreshBlocklistNow() } }
            netMonitor.pathUpdateHandler = { [weak self] path in
                let satisfied = path.status == .satisfied   // capture Sendable value, then hop to main
                Task { @MainActor in
                    guard let self else { return }
                    if satisfied, self.wasOffline {
                        self.wasOffline = false
                        self.refreshBlocklistNow()
                    } else if !satisfied {
                        self.wasOffline = true
                    }
                }
            }
            netMonitor.start(queue: DispatchQueue(label: "pro.vhco.companion.net"))
        }
    }

    private func fileModified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    public func refreshSessions() {
        sessions = sessionIngestor?.summaries(pricing: pricing, repoURL: { [weak self] in self?.repoURL(for: $0) }) ?? []
        resolveRepoURLs()
    }

    /// Pure cache lookup used while building summaries (no git here).
    private func repoURL(for cwd: String?) -> URL? {
        guard let cwd else { return nil }
        return repoURLCache[cwd] ?? nil
    }

    /// Resolve repo URLs for any not-yet-seen project paths off the main thread, then rebuild the
    /// summaries from the now-populated cache (a pure lookup) so the links appear.
    private func resolveRepoURLs() {
        let pending = Set(sessions.compactMap(\.projectPath)).filter { !repoURLCache.keys.contains($0) }
        guard !pending.isEmpty else { return }
        Task.detached(priority: .utility) { [weak self] in
            var resolved: [String: URL?] = [:]
            for cwd in pending { resolved[cwd] = RepoResolver.webURL(forCwd: cwd) }
            await MainActor.run {
                guard let self else { return }
                for (cwd, url) in resolved { self.repoURLCache[cwd] = url }
                self.sessions = self.sessionIngestor?.summaries(
                    pricing: self.pricing, repoURL: { [weak self] in self?.repoURL(for: $0) }) ?? self.sessions
            }
        }
    }

    private func refreshUsageNow() {
        Task { [weak self] in
            let result = await UsageClient().fetch()
            await MainActor.run {
                guard let self else { return }
                switch result {
                case .success(let snap):
                    self.usage = snap; self.usageError = nil; self.usageSignedOut = false
                    self.saveUsage(snap)
                case .failure(let f):
                    self.usageError = Self.describe(f)        // keep last-good `usage`
                    self.usageSignedOut = (f == .noToken)     // only "sign in" when no token
                }
            }
        }
    }

    private var usagePath: String { Paths.configDir + "/usage.json" }
    private func saveUsage(_ s: UsageSnapshot) {
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: URL(fileURLWithPath: usagePath)) }
    }
    private func loadUsage() -> UsageSnapshot? {
        guard let d = FileManager.default.contents(atPath: usagePath) else { return nil }
        return try? JSONDecoder().decode(UsageSnapshot.self, from: d)
    }

    public func toolBreakdown(_ sessionId: String) -> [(tool: String, count: Int)] {
        sessionIngestor?.toolBreakdown(sessionId) ?? []
    }

    private static func describe(_ f: UsageClient.Failure) -> String {
        switch f {
        case .noToken: return "sign in via Claude Code"
        case .http(let c): return "HTTP \(c)"
        case .decode: return "unexpected response"
        case .transport: return "offline"
        }
    }

    /// Manual blocklist refresh (the popover's Refresh button).
    public func refreshBlocklist() { refreshBlocklistNow() }

    private func refreshBlocklistNow() {
        let cfg = config.blocklist
        Task { [weak self] in
            guard let self else { return }
            let result = await self.fetcher.refresh(config: cfg)
            await MainActor.run {
                if result.count > 0 { self.blocklistCount = result.count }
                self.blocklistErrors = result.errors
                self.blocklistUpdatedAt = self.fileModified(Paths.blocklist)
                self.loadBlocklistEntries()
            }
        }
    }

    private func loadBlocklistEntries() {
        guard let text = try? String(contentsOfFile: Paths.blocklist, encoding: .utf8) else {
            blocklistEntries = []; return
        }
        var out: [BlocklistEntry] = []
        out.reserveCapacity(700)
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard let host = parts.first.map(String.init) else { continue }
            let malicious = !(parts.count > 1 && parts[1] == "compromised")
            out.append(BlocklistEntry(host: host, malicious: malicious))
        }
        blocklistEntries = out
    }

    // MARK: Hook installation into ~/.claude/settings.json (explicit user action)

    // The hook is staged to a SPACE-FREE path on install. The embedded bundle path can contain
    // spaces (e.g. ".../public projects/..."), which Claude Code's unquoted hook invocation can't
    // execute - the #1 bug that made the hook silently never fire.
    private var stagedHookPath: String { Paths.configDir + "/companion-hook" }

    private var installer: SettingsInstaller {
        SettingsInstaller(hookCommand: stagedHookPath)
    }

    /// Reveal the shared config dir (rules.yaml, blocklist, audit.ndjson, config.yaml) in Finder
    /// for power users who want to hand-edit. See menubar-ui / v0.2 B3.
    public func openConfigFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: Paths.configDir))
    }

    /// Reveal a session's working directory in Finder (selected in its parent), so you can jump
    /// from a session straight to its project folder. No-op if the path no longer exists.
    public func revealInFinder(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func stageHook() {
        let embedded = Bundle.main.bundlePath + "/Contents/Helpers/companion-hook"
        try? FileManager.default.createDirectory(atPath: Paths.configDir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: stagedHookPath)
        if (try? FileManager.default.copyItem(atPath: embedded, toPath: stagedHookPath)) != nil {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stagedHookPath)
        }
    }

    /// rtk is optional + not bundled; if it's installed we wire its hook for reproducibility (A).
    private func rtkInstalled() -> Bool {
        ["/opt/homebrew/bin/rtk", "/usr/local/bin/rtk",
         ("~/.cargo/bin/rtk" as NSString).expandingTildeInPath]
            .contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func refreshInstallState() { hookInstalled = installer.isInstalled() }
    public func installHook() {
        stageHook()
        try? installer.install(registerRTK: rtkInstalled())
        refreshInstallState()
    }
    public func uninstallHook() { try? installer.uninstall(); refreshInstallState() }

    private func onConfigDirChanged() {
        if configStore.reload() { config = configStore.config }
        compileRules(force: false)       // guarded by content hash → app's own writes don't loop
        pricing = pricingStore.load()    // pick up pricing.yaml edits
        refresh()                        // ingests any new audit lines the hook appended
        notifyNewDenies()                // …then surface any new hard-denials
        refreshSessions()
    }

    private func currentMaxAuditId() -> Int64 {
        guard let db else { return 0 }
        let maxId = try? db.dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT MAX(id) FROM audit")
        }
        return (maxId ?? nil) ?? 0
    }

    /// Post a passive notification for each deny ingested since we last checked (best-effort).
    private func notifyNewDenies() {
        guard config.approval.notifyOnDeny, let db else { return }
        let fresh = (try? db.dbQueue.read { [lastNotifiedAuditId] db in
            try AuditRecord
                .filter(Column("decision") == "deny" && Column("id") > lastNotifiedAuditId)
                .order(Column("id")).fetchAll(db)
        }) ?? []
        for d in fresh {
            let cmd = (d.command ?? d.tool ?? "a command")
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            denyNotifier.post(title: "Claude Companion blocked a command",
                              body: String(cmd.prefix(120)))
        }
        if let maxId = fresh.last?.id { lastNotifiedAuditId = maxId }
    }

    /// Recompile rules.yaml only when its content actually changed (so writing rules.compiled.json
    /// or companion.db - both in the watched dir - doesn't retrigger an endless recompile).
    private func compileRules(force: Bool) {
        let text = (try? String(contentsOfFile: rules.rulesPath, encoding: .utf8)) ?? ""
        let hash = text.hashValue
        guard force || hash != lastRulesHash else { return }
        lastRulesHash = hash
        ruleWarnings = (try? rules.compile()) ?? []
        autoAccept = rules.currentAutoAccept()
    }

    /// Ingest any new audit lines and refresh the in-memory views.
    public func refresh() {
        _ = try? ingestor?.ingestNew()
        guard let db else { return }
        // Only ask/deny (incl. compromised, which is logged as ask) - the actionable tiers.
        recentDecisions = (try? db.dbQueue.read { db in
            try AuditRecord.filter(Column("decision") != "allow")
                .order(Column("id").desc).limit(20).fetchAll(db)
        }) ?? []
        attentionCount = (try? db.dbQueue.read {
            try AuditRecord.filter(Column("decision") != "allow").fetchCount($0)
        }) ?? 0
        totalDecisions = (try? db.dbQueue.read { try AuditRecord.fetchCount($0) }) ?? 0
    }

    // MARK: Actionable decisions (allow-tier.spec.md)

    /// "Always allow this": turn a recent `ask`/compromised decision into a scoped allow exception
    /// in rules.local.yaml. Guarded to `ask` only - a hard `deny` is never allow-overridable here.
    /// The hook honors the exception on its next call (rules.local.yaml is merged at compile time).
    public func alwaysAllow(_ record: AuditRecord) {
        guard record.decision == "ask" else { return }
        let scope = RulesManager.exceptionScope(tool: record.tool, command: record.command,
                                                ruleMatched: record.ruleMatched)
        if let w = try? rules.addAllowException(tool: scope.tool, commandRegex: scope.pattern) {
            ruleWarnings = w
        }
        refresh()
    }

    /// "Block this": add a user deny rule scoped to the decision's tool + pattern.
    public func blockThis(_ record: AuditRecord) {
        let scope = RulesManager.exceptionScope(tool: record.tool, command: record.command,
                                                ruleMatched: record.ruleMatched)
        if let w = try? rules.addDeny(tool: scope.tool, commandRegex: scope.pattern) {
            ruleWarnings = w
        }
        refresh()
    }

    /// Guarded path for a hard `deny`: open the shipped rules.yaml for hand-editing. There is no
    /// silent allow for a deny - the user must consciously edit the rule (see spec).
    public func editDenyRule() {
        NSWorkspace.shared.open(URL(fileURLWithPath: rules.rulesPath))
    }

    /// Kill switch - flip auto_accept in rules.yaml + recompile.
    public func toggleAutoAccept() {
        let newValue = !autoAccept
        if let v = try? rules.setAutoAccept(newValue) {
            autoAccept = v
            lastRulesHash = ((try? String(contentsOfFile: rules.rulesPath, encoding: .utf8)) ?? "").hashValue
        }
    }
}
