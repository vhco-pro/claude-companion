import CompanionKit
import SwiftUI

// The custom menu-bar popover (used with .menuBarExtraStyle(.window)). Richer than the plain
// system menu: colored usage bars, session cards with tool chains + cost, blocklist freshness.

struct PanelView: View {
    @Bindable var model: AppModel
    @State private var blocklistExpanded = false
    @State private var blocklistQuery = ""
    @State private var expandedSession: String?
    @State private var expandedDecision: Int64?
    @State private var remotesExpanded = false
    @State private var newRemoteAlias = ""

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
            Divider()
            decisionsSection
            Divider()
            remotesSection
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
                // Clickable: reveals the working directory in Finder. Styled as a button but
                // kept visually subtle (it's a path, not the headline repo link above).
                Button { model.revealInFinder(p) } label: {
                    Label(p, systemImage: "folder")
                        .lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Reveal \(p) in Finder")
            }
            if let url = s.repoURL {
                // Render as an obvious hyperlink: git-branch glyph, link-colored + underlined
                // label, and a trailing "opens externally" arrow. Without the explicit .link
                // tint it inherits the surrounding .secondary gray and reads as plain text.
                Link(destination: url) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch")
                        Text(repoLabel(url)).underline()
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

    // Decisions that need a human, newest first — ask/deny/compromised only (routine allows are
    // hidden). An `ask` row → one-click allow exception or block; a hard `deny` → guarded rule-edit
    // (no silent allow). The "N of M total" makes clear most calls were auto-approved.
    private var decisionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Needs attention (\(model.attentionCount))").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("last 7d · \(model.totalDecisions) total").font(.caption2).foregroundStyle(.tertiary)
            }
            if model.recentDecisions.isEmpty {
                Text("Nothing needs attention — recent tool calls were all auto-approved.")
                    .font(.caption).foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.recentDecisions.prefix(8), id: \.id) { d in
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
            // Full command, every line. fixedSize(vertical) forces the Text to grow to fit instead
            // of collapsing to one line + "…" - the part that actually matched is often not on the
            // first line (e.g. an `rm` after a leading `cd`). Bounded in a ScrollView so a huge
            // command (e.g. a heredoc) can't push the action buttons off the bottom of the popover.
            if let cmd = d.command, !cmd.isEmpty {
                ScrollView {
                    Text(cmd).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
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

    // Remote-SSH hosts: gate + visibility on remote dev machines (remote-ssh.spec.md). The reload
    // reminder sits OUTSIDE the disclosure so it's always seen (the remote extension host snapshots
    // hooks at start - the gate only takes effect after a window reload).
    private var remotesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let host = model.reloadReminderHost {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.blue)
                    Text("Reload the VSCode window on **\(host)** to activate the hook.")
                        .font(.caption2).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Got it") { model.dismissReloadReminder() }.font(.caption2)
                }
                .padding(6)
                .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }
            DisclosureGroup(isExpanded: $remotesExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.remotes) { r in remoteRow(r) }
                    Divider()
                    addRemoteRow
                }
                .padding(.top, 4)
            } label: {
                Text(remotesSummary).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var remotesSummary: String {
        let n = model.remotes.count
        guard n > 0 else { return "Remotes: none" }
        let down = model.remotes.filter { model.remoteStates[$0.alias]?.reachable == false }.count
        return down > 0 ? "Remotes: \(n) · \(down) unreachable" : "Remotes: \(n)"
    }

    @ViewBuilder
    private func remoteRow(_ r: Remote) -> some View {
        let st = model.remoteStates[r.alias]
        let busy = model.remoteBusy.contains(r.alias)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(remoteColor(st, busy: busy)).frame(width: 7, height: 7)
                Text(r.alias).font(.caption).bold().lineLimit(1)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Re-sync") { model.resyncRemote(r.alias) }.font(.caption2).disabled(busy)
                Button(role: .destructive) { model.removeRemote(r.alias) } label: { Text("Remove") }
                    .font(.caption2).disabled(busy)
            }
            Text(remoteStatusText(st, busy: busy))
                .font(.caption2)
                .foregroundStyle(st?.lastError != nil && !busy ? .red : .secondary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func remoteColor(_ st: RemoteState?, busy: Bool) -> Color {
        if busy { return .blue }
        guard let st else { return .secondary }
        if st.lastError != nil { return .red }
        return st.reachable ? .green : .secondary
    }

    private func remoteStatusText(_ st: RemoteState?, busy: Bool) -> String {
        if busy { return "working…" }
        guard let st else { return "not synced yet" }
        if let err = st.lastError { return "error: \(err)" }
        if let last = st.lastSync { return "synced \(AppModel.relative(last))" }
        return st.reachable ? "reachable" : "not synced yet"
    }

    private var addRemoteRow: some View {
        let available = model.availableSSHHosts()
        return VStack(alignment: .leading, spacing: 6) {
            if !available.isEmpty {
                Menu("Add from ~/.ssh/config…") {
                    ForEach(available, id: \.self) { host in
                        Button(host) { model.addRemote(host) }
                    }
                }
                .font(.caption2)
            }
            HStack {
                TextField("user@host", text: $newRemoteAlias)
                    .textFieldStyle(.roundedBorder).font(.caption2)
                    .onSubmit { submitNewRemote() }
                Button("Add") { submitNewRemote() }
                    .font(.caption2)
                    .disabled(newRemoteAlias.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func submitNewRemote() {
        let alias = newRemoteAlias.trimmingCharacters(in: .whitespaces)
        guard !alias.isEmpty else { return }
        model.addRemote(alias)
        newRemoteAlias = ""
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

private struct DecisionRow: View {
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
    // Flatten newlines/runs of whitespace so a multi-line command reads on one line (otherwise
    // Text+lineLimit(1) shows only the first line - e.g. a harmless `cd …` while the `rm` that
    // actually matched is on a later line). Middle-truncation keeps both ends visible.
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

private struct SessionCard: View {
    let s: SessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(s.active ? Color.green : Color.secondary).frame(width: 7, height: 7)
                Text(s.projectName).bold().lineLimit(1)
                // Remote sessions carry a host chip; local ones stay unadorned (the common case).
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

enum Format {
    static func cost(_ c: Double?) -> String {
        guard let c else { return "—" }
        return c < 0.01 ? "<$0.01" : String(format: "$%.2f", c)
    }
}
