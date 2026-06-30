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
    @State private var expandedSession: String?

    var body: some View {
        let active = model.sessions.filter(\.active)
        VStack(alignment: .leading, spacing: 6) {
            Text("Active sessions (\(active.count))").font(.caption).foregroundStyle(.secondary)
            if active.isEmpty {
                Text("No active sessions right now").font(.caption).foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(active) { s in
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
            }
        }
    }

    private func sessionDetail(_ s: SessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let p = s.projectPath {
                Button { model.revealInFinder(p) } label: {
                    Label(p, systemImage: "folder")
                        .lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Reveal \(p) in Finder")
            }
            if let url = s.repoURL {
                Link(destination: url) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch")
                        Text(PanelFormat.repoLabel(url)).underline()
                        Image(systemName: "arrow.up.right").font(.system(size: 8))
                    }
                    .lineLimit(1)
                }
                .foregroundStyle(.link)
                .help("Open \(url.absoluteString)")
            }
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

// MARK: - Decisions (Needs attention)

struct DecisionsList: View {
    @Bindable var model: AppModel
    /// When true (dashboard), show the search + type filter and don't cap the list.
    var showFilters = false
    @State private var expandedDecision: Int64?
    @State private var query = ""
    @State private var typeFilter = "all"   // all / deny / ask

    private var filtered: [AuditRecord] {
        var rows = model.recentDecisions
        if typeFilter != "all" { rows = rows.filter { $0.decision == typeFilter } }
        let q = query.lowercased()
        if !q.isEmpty { rows = rows.filter { ($0.command ?? "").lowercased().contains(q) } }
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
                            DecisionRow(d: d)
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
            .font(.caption)
        }
        .padding(.leading, 14)
    }
}

struct DecisionRow: View {
    let d: AuditRecord

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
            Text(d.decision).font(.caption2).foregroundStyle(color)
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
