import CompanionKit
import SwiftUI

// The resizable, tabbed dashboard window (plan 12, P3). Opened from the popover's "Open Dashboard"
// button. Composes the same extracted section views as the popover over the one shared AppModel.

struct DashboardView: View {
    @Bindable var model: AppModel
    @State private var tab: Tab = .overview

    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview", sessions = "Sessions", decisions = "Decisions"
        case remotes = "Remotes", settings = "Settings"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .overview: return "gauge.medium"
            case .sessions: return "rectangle.stack"
            case .decisions: return "exclamationmark.shield"
            case .remotes: return "network"
            case .settings: return "gearshape"
            }
        }
    }

    var body: some View {
        TabView(selection: $tab) {
            ForEach(Tab.allCases) { t in
                tabContent(t)
                    .tabItem { Label(t.rawValue, systemImage: t.icon) }
                    .tag(t)
            }
        }
        .frame(minWidth: 640, minHeight: 440)
        .padding(.top, 4)
        .overlay(alignment: .top) {
            ActionFeedbackBanner(model: model).padding(12).frame(maxWidth: 420)
        }
    }

    @ViewBuilder
    private func tabContent(_ t: Tab) -> some View {
        switch t {
        case .overview: overview
        case .sessions: scroll { SessionsList(model: model); Divider(); CostSection(model: model, limit: nil) }
        case .decisions: scroll { DecisionsList(model: model, showFilters: true) }
        case .remotes: scroll { RemotesPanel(model: model) }
        case .settings: scroll { settings }
        }
    }

    // A standard padded, top-aligned scroll container for the busy tabs.
    private func scroll<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) { content() }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Overview

    private var overview: some View {
        scroll {
            statStrip
            Divider()
            Text("Usage").font(.headline)
            UsageSection(model: model)
            Divider()
            Text("Gate").font(.headline)
            ControlsSection(model: model)
            Text(model.hookInstalled ? "Hook installed — tool calls are gated."
                 : "Hook not installed — install it from Settings.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var statStrip: some View {
        let active = model.sessions.filter(\.active).count
        let attention = model.attentionCount
        let cost = model.projectCosts.reduce(0.0) { $0 + $1.cost }
        let down = model.remotes.filter { model.remoteStates[$0.alias]?.reachable == false }.count
        return HStack(spacing: 10) {
            StatTile(title: "Active", value: "\(active)", tint: .green)
            StatTile(title: "Need attention", value: "\(attention)", tint: attention > 0 ? .orange : .secondary)
            StatTile(title: "Cost", value: Format.cost(cost), tint: .primary)
            StatTile(title: "Remotes", value: down > 0 ? "\(model.remotes.count) · \(down)↓" : "\(model.remotes.count)",
                     tint: down > 0 ? .red : .secondary)
        }
    }

    // MARK: Settings

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hook").font(.headline)
            HookControl(model: model)
            Text(model.hookInstalled ? "The PreToolUse gate is installed in ~/.claude/settings.json."
                 : "Install the gate to start auto-approving/denying tool calls.")
                .font(.caption2).foregroundStyle(.secondary)
            Divider()
            Text("Blocklist").font(.headline)
            BlocklistSection(model: model)
            Divider()
            Text("Files").font(.headline)
            HStack {
                Button("Open config folder") { model.openConfigFolder() }
                Button("Refresh now") { model.refresh(); model.refreshSessions() }
            }
        }
    }
}

private struct StatTile: View {
    let title: String
    let value: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.title3).bold().foregroundStyle(tint).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
