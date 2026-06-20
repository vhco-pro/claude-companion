import CompanionKit
import SwiftUI

// The custom menu-bar popover (used with .menuBarExtraStyle(.window)). Richer than the plain
// system menu: colored usage bars, session cards with tool chains + cost, blocklist freshness.

struct PanelView: View {
    @Bindable var model: AppModel
    @State private var blocklistExpanded = false
    @State private var blocklistQuery = ""
    @State private var expandedSession: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            usageSection
            Divider()
            controlsSection
            Divider()
            blocklistSection
            Divider()
            sessionsSection
            if !model.projectCosts.isEmpty {
                Divider(); costSection
            }
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 360)
    }

    // MARK: sections

    private var header: some View {
        HStack {
            Image("MenuBarIcon").resizable().frame(width: 16, height: 16)
            Text("Claude Companion").bold()
            Spacer()
            Text("v\(CompanionKit.version) · \(model.status)").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let u = model.usage {
                UsageBar(label: "Weekly", pct: u.sevenDay?.utilization,
                         reset: resetLabel(u.sevenDay?.resetsAt, dayOfWeek: true))
                UsageBar(label: "5-hour", pct: u.fiveHour?.utilization,
                         reset: resetLabel(u.fiveHour?.resetsAt, dayOfWeek: false))
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

    /// ISO8601 reset timestamp → local "EEE HH:mm" (weekly → day of week + time) or "HH:mm"
    /// (5-hour → just the time). Local timezone; nil if unparseable.
    private func resetLabel(_ iso: String?, dayOfWeek: Bool) -> String? {
        guard let iso else { return nil }
        let withFrac = ISO8601DateFormatter(); withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        guard let date = withFrac.date(from: iso) ?? plain.date(from: iso) else { return nil }
        let f = DateFormatter()
        f.dateFormat = dayOfWeek ? "EEE HH:mm" : "HH:mm"
        return f.string(from: date)
    }

    /// Compact repo label, e.g. "owner/repo" (drops Azure's "_git" segment).
    private func repoLabel(_ url: URL) -> String {
        let parts = url.path.split(separator: "/").map(String.init).filter { $0 != "_git" }
        return parts.suffix(2).joined(separator: "/")
    }

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { model.autoAccept }, set: { _ in model.toggleAutoAccept() })) {
                Text("Auto-accept").bold()
            }
            .toggleStyle(.switch)
            Text("Kill switch: ⌃⌥⌘A").font(.caption2).foregroundStyle(.secondary)
            if !model.ruleWarnings.isEmpty {
                Text("⚠️ \(model.ruleWarnings.count) rule warning(s)").font(.caption2).foregroundStyle(.orange)
            }
            Button(model.hookInstalled ? "Remove hook from Claude Code" : "Install hook into Claude Code") {
                model.hookInstalled ? model.uninstallHook() : model.installHook()
            }
        }
    }

    private var blocklistSection: some View {
        DisclosureGroup(isExpanded: $blocklistExpanded) {
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
                .frame(height: 180)
            }
            .padding(.top, 4)
        } label: {
            Text(model.blocklistSummary).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var sessionsSection: some View {
        // Only currently-active sessions (recent activity). Old/idle sessions are excluded from
        // the list - they'd otherwise look "open" when they're done. Cost-by-project keeps all.
        let active = model.sessions.filter(\.active)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Active sessions (\(active.count))").font(.caption).foregroundStyle(.secondary)
            if active.isEmpty {
                Text("No active sessions right now").font(.caption).foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(active.prefix(8)) { s in
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

    // Detail shows what the card DOESN'T: full cwd, start time, and per-tool call counts.
    private func sessionDetail(_ s: SessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let p = s.projectPath {
                Text(p).lineLimit(1).truncationMode(.middle).foregroundStyle(.tertiary)
            }
            if let url = s.repoURL {
                Link(destination: url) {
                    Label(repoLabel(url), systemImage: "chevron.left.forwardslash.chevron.right")
                        .lineLimit(1)
                }
                .help(url.absoluteString)
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

    private var costSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Cost by project (session totals)").font(.caption).foregroundStyle(.secondary)
            ForEach(model.projectCosts.prefix(5)) { p in
                HStack { Text(p.id).lineLimit(1); Spacer(); Text(Format.cost(p.cost)) }.font(.caption)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Refresh") { model.refresh(); model.refreshSessions() }
            Button("Config") { model.openConfigFolder() }
                .help("Open the config folder (rules, blocklist, audit) in Finder")
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
        }
    }
}

// MARK: - Subviews

private struct UsageBar: View {
    let label: String
    let pct: Double?
    var reset: String? = nil          // e.g. "Thu 22:00" (weekly) or "20:00" (5-hour)

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

private struct SessionCard: View {
    let s: SessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(s.active ? Color.green : Color.secondary).frame(width: 7, height: 7)
                Text(s.projectName).bold().lineLimit(1)
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

enum Format {
    static func cost(_ c: Double?) -> String {
        guard let c else { return "—" }
        return c < 0.01 ? "<$0.01" : String(format: "$%.2f", c)
    }
}
