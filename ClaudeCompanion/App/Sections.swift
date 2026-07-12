import CompanionKit
import SwiftUI

// Reusable section views extracted from the old single-scroll PanelView (plan 12, P1). The compact
// popover (PanelView) and the tabbed dashboard window (DashboardView) both compose these, so there
// is one source of truth for each piece of UI. Behavior is unchanged from v0.5.7; only the
// container moved.

// MARK: - Shared formatting helpers

enum PanelFormat {
    /// ISO8601 reset timestamp → local "EEE HH:mm" (weekly) or "HH:mm" (5-hour). nil if unparseable.
    static func resetLabel(_ iso: String?, dayOfWeek: Bool) -> String? {
        guard let iso else { return nil }
        let withFrac = ISO8601DateFormatter(); withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        guard let date = withFrac.date(from: iso) ?? plain.date(from: iso) else { return nil }
        let f = DateFormatter()
        f.dateFormat = dayOfWeek ? "EEE HH:mm" : "HH:mm"
        return f.string(from: date)
    }

    /// Compact repo label, e.g. "owner/repo" (drops Azure's "_git" segment).
    static func repoLabel(_ url: URL) -> String {
        let parts = url.path.split(separator: "/").map(String.init).filter { $0 != "_git" }
        return parts.suffix(2).joined(separator: "/")
    }

    /// "parent / leaf" breadcrumb for a project path, so repeated leaf names (vitepress, vega) are
    /// disambiguated by their parent folder. Returns just the leaf when there's no parent.
    static func projectLabel(path: String?, fallback: String) -> (parent: String?, leaf: String) {
        guard let path, !path.isEmpty else { return (nil, fallback) }
        let comps = path.split(separator: "/").map(String.init)
        guard let leaf = comps.last else { return (nil, fallback) }
        return (comps.count >= 2 ? comps[comps.count - 2] : nil, leaf)
    }
}

enum Format {
    static func cost(_ c: Double?) -> String {
        guard let c else { return "—" }
        return c < 0.01 ? "<$0.01" : String(format: "$%.2f", c)
    }
}

// MARK: - Usage

struct UsageSection: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let u = model.usage {
                UsageBar(label: "Weekly", pct: u.sevenDay?.utilization,
                         reset: PanelFormat.resetLabel(u.sevenDay?.resetsAt, dayOfWeek: true))
                UsageBar(label: "5-hour", pct: u.fiveHour?.utilization,
                         reset: PanelFormat.resetLabel(u.fiveHour?.resetsAt, dayOfWeek: false))
                HStack(spacing: 10) {
                    if let s = u.sevenDaySonnet?.utilization { Text("sonnet 7d \(Int(s))%") }
                    if let o = u.sevenDayOpus?.utilization { Text("opus 7d \(Int(o))%") }
                }.font(.caption2).foregroundStyle(.secondary)
                // Freshness line - so a wedged/failed refresh shows itself instead of the bars
                // silently serving last-good numbers as if current (usage-refresh-resilience.spec).
                if let at = model.usageUpdatedAt {
                    HStack(spacing: 4) {
                        Text("updated \(AppModel.relative(at))")
                        if model.usageStale { Text("⚠️ stale").foregroundStyle(.orange) }
                    }.font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text(model.usageSignedOut ? "Sign in via Claude Code"
                     : (model.usageError.map { "Usage unavailable (\($0)) - retrying" } ?? "Usage: loading…"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct UsageBar: View {
    let label: String
    let pct: Double?
    var reset: String? = nil

    private var color: Color {
        guard let p = pct else { return .gray }
        return p < 50 ? .green : (p < 80 ? .orange : .red)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(label).font(.caption)
                if let reset { Text("· resets \(reset)").font(.caption2).foregroundStyle(.secondary) }
                Spacer()
                Text(pct.map { "\(Int($0.rounded()))%" } ?? "—").font(.caption).monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.gray.opacity(0.2))
                    RoundedRectangle(cornerRadius: 3).fill(color)
                        .frame(width: geo.size.width * CGFloat(min(100, max(0, pct ?? 0)) / 100))
                }
            }
            .frame(height: 6)
        }
    }
}

// MARK: - Controls (auto-accept + kill switch + rule warnings)

struct ControlsSection: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { model.autoAccept }, set: { _ in model.toggleAutoAccept() })) {
                Text("Auto-accept").bold()
            }
            .toggleStyle(.switch)
            Text("Kill switch: ⌃⌥⌘A").font(.caption2).foregroundStyle(.secondary)
            if !model.ruleWarnings.isEmpty {
                Text("⚠️ \(model.ruleWarnings.count) rule warning(s)").font(.caption2).foregroundStyle(.orange)
            }
        }
    }
}

// MARK: - Hook install/remove (its own control; lives in Settings now)

struct HookControl: View {
    @Bindable var model: AppModel

    var body: some View {
        Button(model.hookInstalled ? "Remove hook from Claude Code" : "Install hook into Claude Code") {
            model.hookInstalled ? model.uninstallHook() : model.installHook()
        }
    }
}

// MARK: - Blocklist

struct BlocklistSection: View {
    @Bindable var model: AppModel
    @State private var blocklistQuery = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Search domains…", text: $blocklistQuery)
                    .textFieldStyle(.roundedBorder)
                Button("Refresh") { model.refreshBlocklist() }
            }
            let q = blocklistQuery.lowercased()
            let filtered = q.isEmpty ? model.blocklistEntries
                : model.blocklistEntries.filter { $0.host.contains(q) }
            Text("\(filtered.count) domains")
                .font(.caption2).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filtered) { e in
                        HStack {
                            Text(e.host).font(.caption).lineLimit(1)
                            Spacer()
                            Text(e.classLabel).font(.caption2)
                                .foregroundStyle(e.malicious ? .red : .orange)
                        }
                    }
                }
            }
            .frame(minHeight: 180)
        }
    }
}

// MARK: - Sessions

struct SessionsList: View {
    @Bindable var model: AppModel
    /// Popover passes a small cap (e.g. 3); the dashboard leaves it nil (show all groups).
    var limit: Int? = nil
    @State private var expandedGroup: String?
    @State private var expandedSession: String?

    var body: some View {
        let all = model.activeSessionGroups
        let groups = limit.map { Array(all.prefix($0)) } ?? all
        let total = all.reduce(0) { $0 + $1.sessionCount }
        VStack(alignment: .leading, spacing: 6) {
            Text("Active sessions (\(total) in \(all.count) project\(all.count == 1 ? "" : "s"))")
                .font(.caption).foregroundStyle(.secondary)
            if groups.isEmpty {
                Text("No active sessions right now").font(.caption).foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(groups) { g in
                        VStack(alignment: .leading, spacing: 4) {
                            ProjectGroupCard(model: model, g: g, expanded: expandedGroup == g.id)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    expandedGroup = (expandedGroup == g.id) ? nil : g.id
                                }
                            // Expanded. A single-session project goes straight to its detail (the
                            // group card already IS that session - no duplicate card). A multi-session
                            // project lists its member sessions, each tappable to its own detail.
                            if expandedGroup == g.id {
                                if g.sessionCount == 1, let only = g.sessions.first {
                                    sessionDetail(only)
                                } else {
                                    VStack(alignment: .leading, spacing: 6) {
                                        ForEach(g.sessions) { s in
                                            VStack(alignment: .leading, spacing: 4) {
                                                SessionCard(s: s)
                                                    .contentShape(Rectangle())
                                                    .onTapGesture {
                                                        expandedSession = (expandedSession == s.id) ? nil : s.id
                                                    }
                                                if expandedSession == s.id { sessionDetail(s) }
                                            }
                                        }
                                    }
                                    .padding(.leading, 12)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // Detail = the per-session stuff the card doesn't already show. The cwd path + repo link live on
    // the group card (clickable without expanding), so they're intentionally NOT repeated here.
    private func sessionDetail(_ s: SessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                if let started = s.startedAt { Text("started \(AppModel.relative(started))") }
                Text("⊡cache \(AppModel.fmtTokens(s.cacheTokens))")
            }
            let tb = model.toolBreakdown(s.id)
            if !tb.isEmpty {
                Text(tb.map { "\($0.tool) ×\($0.count)" }.joined(separator: "   "))
                    .foregroundStyle(.primary)
            }
        }
        .font(.caption2).foregroundStyle(.secondary)
        .padding(.leading, 14)
    }
}

struct SessionCard: View {
    let s: SessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(s.active ? Color.green : Color.secondary).frame(width: 7, height: 7)
                Text(s.projectName).bold().lineLimit(1)
                if s.host != "local" {
                    Text(s.host)
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                        .foregroundStyle(.tint)
                        .lineLimit(1)
                }
                Spacer()
                Text((s.model ?? "?").replacingOccurrences(of: "claude-", with: ""))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text("\(s.toolCount) tools")
                Text("↓\(AppModel.fmtTokens(s.inputTokens))")
                Text("↑\(AppModel.fmtTokens(s.outputTokens))")
                if let c = s.costUSD { Text(Format.cost(c)) }
            }
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            if !s.recentTools.isEmpty {
                Text(s.recentTools.reversed().joined(separator: " › "))
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
    }
}

// One card per project, aggregating its active sessions (session-grouping.spec.md). A `N sessions`
// badge appears only when there's more than one; tapping the card reveals the member sessions.
struct ProjectGroupCard: View {
    @Bindable var model: AppModel
    let g: ProjectSessionGroup
    var expanded = false

    private var modelLabel: String {
        g.models.prefix(2).map { $0.replacingOccurrences(of: "claude-", with: "") }
            .joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                Circle().fill(Color.green).frame(width: 7, height: 7)
                let label = PanelFormat.projectLabel(path: g.id, fallback: g.projectName)
                HStack(spacing: 0) {
                    if let parent = label.parent {
                        Text(parent + " / ").foregroundStyle(.secondary)
                    }
                    Text(label.leaf).bold()
                }
                .lineLimit(1)
                if g.sessionCount > 1 {
                    Text("\(g.sessionCount) sessions")
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.2), in: Capsule())
                        .foregroundStyle(.secondary)
                }
                if g.host != "local" {
                    Text(g.host)
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                        .foregroundStyle(.tint).lineLimit(1)
                }
                Spacer()
                Text(modelLabel).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 8) {
                Text("\(g.toolCount) tools")
                Text("↓\(AppModel.fmtTokens(g.inputTokens))")
                Text("↑\(AppModel.fmtTokens(g.outputTokens))")
                if let c = g.costUSD { Text(Format.cost(c)) }
            }
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            // Clickable git repo link + Finder path right on the card - the whole point is to reach
            // them without expanding, so they live here (not in the expanded detail).
            if let url = g.repoURL {
                Link(destination: url) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch")
                        Text(PanelFormat.repoLabel(url)).underline()
                        Image(systemName: "arrow.up.right").font(.system(size: 8))
                    }
                    .font(.caption2).lineLimit(1)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.link)
                .help("Open \(url.absoluteString)")
            }
            if let p = g.projectPath {
                Button { model.revealInFinder(p) } label: {
                    Label(p, systemImage: "folder").font(.caption2)
                        .lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.plain).foregroundStyle(.tertiary)
                .help("Reveal \(p) in Finder")
            }
            if !g.recentTools.isEmpty {
                Text(g.recentTools.reversed().joined(separator: " › "))
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
    }
}

// MARK: - Action feedback toast (decision-action-feedback.spec.md)

// Transient confirmation after Always-allow / Block. Mounted as a top overlay on both the popover
// and the dashboard so it appears wherever the action was taken. Renders nothing when there's no
// feedback; the model self-clears it after ~3s and a tap dismisses it immediately.
struct ActionFeedbackBanner: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if let f = model.actionFeedback {
                let allow = f.kind == .allow
                HStack(spacing: 8) {
                    Image(systemName: allow ? "checkmark.shield.fill" : "xmark.shield.fill")
                        .foregroundStyle(allow ? .green : .red)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(allow ? "Always allowing" : "Blocking").font(.caption).bold()
                        Text(f.summary).font(.caption2).lineLimit(1).truncationMode(.middle)
                        Text("applies on next call").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder((allow ? Color.green : Color.red).opacity(0.4)))
                .shadow(radius: 4, y: 2)
                .contentShape(Rectangle())
                .onTapGesture { model.dismissFeedback() }
                .transition(.move(edge: .top).combined(with: .opacity))
                .id(f.id)
            }
        }
        .animation(.spring(duration: 0.25), value: model.actionFeedback)
    }
}

// MARK: - Decisions (Needs attention)

struct DecisionsList: View {
    @Bindable var model: AppModel
    /// When true (dashboard), show the search + type filter and don't cap the list.
    var showFilters = false
    /// Explicit cap (popover passes 3). nil → all when filtering, else the default 8.
    var limit: Int? = nil
    @State private var expandedDecision: Int64?
    @State private var query = ""
    @State private var typeFilter = "all"   // all / deny / ask

    private var filtered: [AuditRecord] {
        var rows = model.recentDecisions
        if typeFilter != "all" { rows = rows.filter { $0.decision == typeFilter } }
        let q = query.lowercased()
        if !q.isEmpty { rows = rows.filter { ($0.command ?? "").lowercased().contains(q) } }
        if let limit { return Array(rows.prefix(limit)) }
        return showFilters ? rows : Array(rows.prefix(8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Needs attention (\(model.attentionCount))").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("last 7d · \(model.totalDecisions) total").font(.caption2).foregroundStyle(.tertiary)
            }
            if showFilters {
                HStack(spacing: 8) {
                    TextField("Filter commands…", text: $query).textFieldStyle(.roundedBorder)
                    Picker("", selection: $typeFilter) {
                        Text("All").tag("all"); Text("Deny").tag("deny"); Text("Ask").tag("ask")
                    }
                    .pickerStyle(.segmented).fixedSize()
                }
            }
            if model.recentDecisions.isEmpty {
                Text("Nothing needs attention — recent tool calls were all auto-approved.")
                    .font(.caption).foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(filtered, id: \.id) { d in
                        VStack(alignment: .leading, spacing: 4) {
                            DecisionRow(d: d, actioned: d.id.flatMap { model.actionedDecisions[$0] })
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    expandedDecision = (expandedDecision == d.id) ? nil : d.id
                                }
                            if expandedDecision == d.id { decisionActions(d) }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func decisionActions(_ d: AuditRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // When the decision was surfaced - only in the expanded detail, not on every row.
            if let when = AppModel.absolute(iso: d.ts) {
                let ago = AppModel.relative(iso: d.ts).map { " · \($0)" } ?? ""
                Text("surfaced \(when)\(ago)").font(.caption2).foregroundStyle(.tertiary)
            }
            if let cmd = d.command, !cmd.isEmpty {
                ScrollView {
                    Text(cmd).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
            }
            if let rule = d.ruleMatched, !rule.isEmpty {
                Text("matched: \(rule)").font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                // Already actioned this session - show the outcome, not the buttons (you can't
                // re-allow what you just allowed). The exception applies on the hook's next call.
                if let kind = d.id.flatMap({ model.actionedDecisions[$0] }) {
                    Label(kind == .allow ? "Now always-allowed · applies on next call"
                                         : "Now blocked · applies on next call",
                          systemImage: "checkmark")
                        .font(.caption2).foregroundStyle(kind == .allow ? .green : .red)
                } else {
                    switch d.decision {
                    case "ask":
                        Button("Always allow this") { model.alwaysAllow(d); expandedDecision = nil }
                        Button("Block this") { model.blockThis(d); expandedDecision = nil }
                    case "deny":
                        Button("Edit deny rule…") { model.editDenyRule() }
                            .help("Hard denies can't be allowed from here — edit rules.yaml directly, with care.")
                        Text("can't allow a hard deny").font(.caption2).foregroundStyle(.secondary)
                    default:
                        Text("already allowed").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .font(.caption)
        }
        .padding(.leading, 14)
    }
}

struct DecisionRow: View {
    let d: AuditRecord
    /// Set once the user has allowed/blocked this row (decision-action-feedback.spec.md); swaps the
    /// trailing tier label for an outcome badge so a later glance still shows what was done.
    var actioned: AppModel.DecisionActionKind? = nil

    private var color: Color {
        switch d.decision {
        case "deny": return .red
        case "ask": return .orange
        default: return .green
        }
    }
    private var icon: String {
        switch d.decision {
        case "deny": return "xmark.shield.fill"
        case "ask": return "questionmark.diamond.fill"
        default: return "checkmark.shield.fill"
        }
    }
    private var oneLine: String {
        (d.command ?? d.tool ?? "—").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(color).font(.caption2)
            Text(oneLine).font(.caption).lineLimit(1).truncationMode(.middle)
            Spacer()
            if let actioned {
                Label(actioned == .allow ? "allowed" : "blocked", systemImage: "checkmark")
                    .labelStyle(.titleAndIcon)
                    .font(.caption2).foregroundStyle(actioned == .allow ? .green : .red)
            } else {
                Text(d.decision).font(.caption2).foregroundStyle(color)
            }
        }
    }
}

// MARK: - Cost by project

struct CostSection: View {
    @Bindable var model: AppModel
    /// Popover capped to 5; dashboard shows all.
    var limit: Int? = 5

    var body: some View {
        let rows = limit.map { Array(model.projectCosts.prefix($0)) } ?? model.projectCosts
        VStack(alignment: .leading, spacing: 3) {
            Text("Cost by project (session totals)").font(.caption).foregroundStyle(.secondary)
            ForEach(rows) { p in
                HStack { Text(p.id).lineLimit(1); Spacer(); Text(Format.cost(p.cost)) }.font(.caption)
            }
        }
    }
}
