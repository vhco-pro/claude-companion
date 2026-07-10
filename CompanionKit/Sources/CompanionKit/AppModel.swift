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
    /// Confirmation feedback after the user acts on a surfaced decision
    /// (decision-action-feedback.spec.md). `actionFeedback` is the transient toast (nil = none);
    /// `actionedDecisions` maps a decision-record id → the action taken, driving the persistent row
    /// mark. Both are in-memory; the durable truth is the exception written to rules.local.yaml.
    public private(set) var actionFeedback: ActionFeedback?
    public private(set) var actionedDecisions: [Int64: DecisionActionKind] = [:]
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

    /// Active sessions collapsed by project (session-grouping.spec.md). "Active" here is the
    /// recency window AND an activity floor (≥1 tool call) - so empty/no-model sessions don't leak
    /// in. Drives the Sessions tab + the popover's top-3 glance.
    public var activeSessionGroups: [ProjectSessionGroup] {
        SessionGrouping.groupByProject(sessions.filter { $0.active && $0.toolCount > 0 })
    }

    public struct BlocklistEntry: Identifiable, Sendable {
        public let host: String
        public let malicious: Bool          // false = compromised
        public var id: String { host }
        public var classLabel: String { malicious ? "malicious" : "compromised" }
    }

    /// Which action the user took on a decision - drives both the toast copy and the row mark. The
    /// view maps this to color/icon (as `DecisionRow` already does for a decision tier).
    public enum DecisionActionKind: String, Sendable { case allow, block }

    /// A one-shot confirmation toast. `id` is monotonic so replacing the toast re-triggers the
    /// SwiftUI transition and so a stale auto-dismiss timer never clears a newer toast.
    public struct ActionFeedback: Identifiable, Sendable, Equatable {
        public let id: Int
        public let kind: DecisionActionKind
        public let summary: String
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

    public nonisolated static func relative(_ date: Date) -> String {
        let secs = Int(Date().timeIntervalSince(date))
        if secs < 60 { return "just now" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        if secs < 86400 { return "\(secs / 3600)h ago" }
        return "\(secs / 86400)d ago"
    }

    /// Relative label ("2h ago") for an ISO8601 audit timestamp (e.g. `AuditRecord.ts` - when the
    /// decision was surfaced). nil when the string is absent or unparseable, so the UI can skip it.
    public nonisolated static func relative(iso: String?) -> String? {
        guard let iso, let date = parseISO(iso) else { return nil }
        return relative(date)
    }

    /// Compact absolute local label ("Jul 9, 01:33") for an ISO8601 audit timestamp - shown in the
    /// expanded decision detail where a precise instant is wanted. nil when absent/unparseable.
    public nonisolated static func absolute(iso: String?) -> String? {
        guard let iso, let date = parseISO(iso) else { return nil }
        let f = DateFormatter(); f.dateFormat = "MMM d, HH:mm"
        return f.string(from: date)
    }

    /// Human one-line label for a decision the user just actioned - shown in the confirmation toast
    /// and (indirectly) the row mark. The command collapsed to a single spaced line and truncated,
    /// falling back to the tool name, then `—`. Pure (decision-action-feedback.spec.md).
    public nonisolated static func actionSummary(_ record: AuditRecord) -> String {
        if let cmd = record.command?.split(whereSeparator: \.isWhitespace).joined(separator: " "),
           !cmd.isEmpty {
            return cmd.count > 60 ? String(cmd.prefix(60)) + "…" : cmd
        }
        if let tool = record.tool, !tool.isEmpty { return tool }
        return "—"
    }

    /// Parse an ISO8601 instant tolerating both the plain `…Z` form the hook writes and the
    /// fractional-seconds form (same two-formatter fallback as `PanelFormat.resetLabel`).
    private nonisolated static func parseISO(_ iso: String) -> Date? {
        let withFrac = ISO8601DateFormatter(); withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        return withFrac.date(from: iso) ?? plain.date(from: iso)
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
    // MARK: remote-ssh (remote-ssh.spec.md)
    private let remotesStore = RemotesStore()
    private let remoteStateStore = RemoteStateStore()
    private var remoteSync: RemoteSync?
    private var remoteSyncTimer: Timer?
    public private(set) var remotes: [Remote] = []
    public private(set) var remoteStates: [String: RemoteState] = [:]
    /// Hosts mid register/sync (UI spinner).
    public private(set) var remoteBusy: Set<String> = []
    /// Set after a successful register - the UI shows "reload the VSCode window" (the remote
    /// extension host snapshots hooks at start). Cleared when the user dismisses it.
    public private(set) var reloadReminderHost: String?
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
            remoteSync = RemoteSync(db: database)
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
        if hookInstalled { stageHook() }   // keep the staged hook current after an app upgrade
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

        // Remote-SSH: load registered hosts, do an initial pull, then poll on a slow timer + wake.
        remotes = remotesStore.load()
        refreshRemoteStates()
        if !remotes.isEmpty {
            syncRemotesNow()
            remoteSyncTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.syncRemotesNow() }
            }
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in Task { @MainActor in self?.syncRemotesNow() } }
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
        // Resolve from the working subfolder where known (the launch cwd may not be a repo).
        let pending = Set(sessions.compactMap { $0.workingPath ?? $0.projectPath })
            .filter { !repoURLCache.keys.contains($0) }
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

    /// Copy the embedded hook to the space-free staged path. Atomic (copy to a temp, then rename(2))
    /// so a concurrent hook invocation never sees a missing/partial binary (which would fail OPEN).
    /// No-ops when the staged hook already matches (same size) - so calling it on every launch is
    /// cheap and keeps the staged binary current across app upgrades.
    private func stageHook() {
        let fm = FileManager.default
        let embedded = Bundle.main.bundlePath + "/Contents/Helpers/companion-hook"
        guard fm.fileExists(atPath: embedded) else { return }
        let eSize = (try? fm.attributesOfItem(atPath: embedded))?[.size] as? Int
        let sSize = (try? fm.attributesOfItem(atPath: stagedHookPath))?[.size] as? Int
        if let e = eSize, e == sSize { return }   // already current
        try? fm.createDirectory(atPath: Paths.configDir, withIntermediateDirectories: true)
        let tmp = stagedHookPath + ".staging"
        try? fm.removeItem(atPath: tmp)
        guard (try? fm.copyItem(atPath: embedded, toPath: tmp)) != nil else { return }
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp)
        // The embedded hook is copied out of the (often quarantined) app bundle, so it inherits
        // com.apple.quarantine. A quarantined ad-hoc binary is killed by Gatekeeper when Claude Code
        // executes it - which makes the gate vanish/flap. Strip it so the staged hook always runs.
        tmp.withCString { _ = removexattr($0, "com.apple.quarantine", 0) }   // ENOATTR if absent → fine
        if rename(tmp, stagedHookPath) != 0 { try? fm.removeItem(atPath: tmp) }   // atomic replace
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
        pushRulesToRemotes()   // a real rules change → propagate to every registered remote
    }

    /// "Needs attention" is scoped to recent activity - a lifetime count of every ask/deny ever
    /// (which only grows) reads as a perpetual backlog, not something actionable now.
    public static let attentionWindowDays = 7.0

    private static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter(); return f.string(from: date)
    }

    /// Ingest any new audit lines and refresh the in-memory views.
    public func refresh() {
        _ = try? ingestor?.ingestNew()
        guard let db else { return }
        // Only ask/deny (incl. compromised, which is logged as ask) - the actionable tiers - and
        // only within the recent window (older decisions are history, not a live to-do list).
        let cutoff = Self.iso(Date().addingTimeInterval(-Self.attentionWindowDays * 86_400))
        let actionable = AuditRecord.filter(Column("decision") != "allow" && Column("ts") >= cutoff)
        recentDecisions = (try? db.dbQueue.read { db in
            try actionable.order(Column("id").desc).limit(20).fetchAll(db)
        }) ?? []
        attentionCount = (try? db.dbQueue.read { try actionable.fetchCount($0) }) ?? 0
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
        markActioned(record, .allow)
        refresh()
    }

    /// "Block this": add a user deny rule scoped to the decision's tool + pattern.
    public func blockThis(_ record: AuditRecord) {
        let scope = RulesManager.exceptionScope(tool: record.tool, command: record.command,
                                                ruleMatched: record.ruleMatched)
        if let w = try? rules.addDeny(tool: scope.tool, commandRegex: scope.pattern) {
            ruleWarnings = w
        }
        markActioned(record, .block)
        refresh()
    }

    // MARK: Action feedback (decision-action-feedback.spec.md)

    private var feedbackSeq = 0

    /// Record the row mark for a just-actioned decision and raise its confirmation toast. The row
    /// mark is keyed by the stable `AuditRecord.id` so it survives the `refresh()` that follows.
    private func markActioned(_ record: AuditRecord, _ kind: DecisionActionKind) {
        if let id = record.id { actionedDecisions[id] = kind }
        feedbackSeq += 1
        let seq = feedbackSeq
        actionFeedback = ActionFeedback(id: seq, kind: kind, summary: Self.actionSummary(record))
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if feedbackSeq == seq { actionFeedback = nil }   // a newer toast wins; don't clear it
        }
    }

    /// Dismiss the current toast immediately (tap-to-dismiss).
    public func dismissFeedback() { actionFeedback = nil }

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
            pushRulesToRemotes()   // kill-switch is high-priority: push immediately, don't wait
        }
    }

    // MARK: Remote-SSH orchestration

    /// SSH-config hosts not already registered (the "Add remote…" picker source).
    public func availableSSHHosts() -> [String] {
        let registered = Set(remotes.map(\.alias))
        return SSHConfigParser.aliases().filter { !registered.contains($0) }
    }

    private func refreshRemoteStates() {
        var m: [String: RemoteState] = [:]
        for r in remotes { m[r.alias] = remoteStateStore.load(alias: r.alias) }
        remoteStates = m
    }

    /// Seed the repo-link cache with URLs the sync resolved over SSH, so remote sessions get
    /// quicklinks (the local git resolver can't reach a remote cwd). Overwrites any nil the local
    /// resolver may have cached for that remote path.
    private func mergeRemoteRepoURLs() {
        guard let sync = remoteSync else { return }
        for (cwd, url) in sync.remoteRepoURLs() { repoURLCache[cwd] = url }
    }

    public func dismissReloadReminder() { reloadReminderHost = nil }

    /// Register a host: install the Linux hook + rules + merge settings (over SSH), then persist it
    /// and do a first pull. Runs off-main (SSH + a ~55 MB download); updates the UI on completion.
    public func addRemote(_ alias: String) {
        let alias = alias.trimmingCharacters(in: .whitespaces)
        guard let sync = remoteSync, !alias.isEmpty,
              !remotes.contains(where: { $0.alias == alias }) else { return }
        remoteBusy.insert(alias)
        Task.detached { [weak self] in
            var err: String?
            do {
                try await sync.register(Remote(alias: alias))
                await sync.syncOnce(Remote(alias: alias))
                try? sync.pushRules(to: Remote(alias: alias))
            } catch { err = RemoteSync.describe(error) }
            await MainActor.run {
                guard let self else { return }
                self.remoteBusy.remove(alias)
                if let err {
                    var st = self.remoteStateStore.load(alias: alias)
                    st.lastError = err; st.reachable = false
                    self.remoteStateStore.save(alias: alias, st)
                } else {
                    self.remotes = (try? self.remotesStore.add(alias: alias)) ?? self.remotes
                    self.reloadReminderHost = alias
                }
                self.refreshRemoteStates()
                self.mergeRemoteRepoURLs()
                self.refreshSessions()
            }
        }
    }

    /// Remove a host: uninstall our remote hook entries, then forget it locally.
    public func removeRemote(_ alias: String) {
        guard let sync = remoteSync else { return }
        remoteBusy.insert(alias)
        Task.detached { [weak self] in
            try? sync.deregister(Remote(alias: alias))
            await MainActor.run {
                guard let self else { return }
                self.remoteBusy.remove(alias)
                self.remotes = (try? self.remotesStore.remove(alias: alias)) ?? self.remotes
                self.remoteStates[alias] = nil
                self.refreshSessions()
            }
        }
    }

    /// Manual re-sync of one host (the Remotes UI button).
    public func resyncRemote(_ alias: String) {
        guard let sync = remoteSync, let r = remotes.first(where: { $0.alias == alias }) else { return }
        remoteBusy.insert(alias)
        Task.detached { [weak self] in
            await sync.syncOnce(r)
            await MainActor.run {
                self?.remoteBusy.remove(alias); self?.refreshRemoteStates()
                self?.mergeRemoteRepoURLs(); self?.refreshSessions(); self?.checkReloadReminders()
            }
        }
    }

    /// Pull every enabled remote once, off-main, then refresh the UI.
    private func syncRemotesNow() {
        guard let sync = remoteSync, !remotes.isEmpty else { return }
        let rs = remotes
        Task.detached { [weak self] in
            for r in rs { await sync.syncOnce(r) }
            await MainActor.run {
                self?.refreshRemoteStates(); self?.mergeRemoteRepoURLs()
                self?.refreshSessions(); self?.checkReloadReminders()
            }
        }
    }

    /// After a sync, if a host got a NEW hook pushed (its `hookVersion` advanced past what we last
    /// reminded for), nudge the user to reload that VSCode window - once per version, not every cycle.
    private func checkReloadReminders() {
        for r in remotes {
            var st = remoteStateStore.load(alias: r.alias)
            var remind = false
            if RemoteState.shouldRemindReload(hookVersion: st.hookVersion,
                                              lastReminded: st.lastRemindedHookVersion) {
                st.lastRemindedHookVersion = st.hookVersion
                remind = true
            }
            if st.needsReload {            // settings were re-wired this sync
                st.needsReload = false
                remind = true
            }
            if remind {
                reloadReminderHost = r.alias
                remoteStateStore.save(alias: r.alias, st)
            }
        }
    }

    /// Push the freshly-compiled rules to every enabled remote (best-effort; records per-host error).
    private func pushRulesToRemotes() {
        guard let sync = remoteSync else { return }
        let rs = remotes.filter(\.enabled)
        guard !rs.isEmpty else { return }
        Task.detached { [weak self] in
            for r in rs {
                do { try sync.pushRules(to: r) }
                catch {
                    let msg = RemoteSync.describe(error)
                    await MainActor.run {
                        guard let self else { return }
                        var st = self.remoteStateStore.load(alias: r.alias); st.lastError = msg
                        self.remoteStateStore.save(alias: r.alias, st)
                        self.remoteStates[r.alias] = st
                    }
                }
            }
        }
    }
}
