import CompanionKit
import SwiftUI

// The compact menu-bar popover (plan 12, P4): a fixed, content-sized glance that never scrolls,
// regardless of how many sessions/decisions exist. Everything that grows with activity lives in the
// dashboard window (DashboardView), opened from here. Both share the one AppModel + the extracted
// section views.

struct PanelView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            UsageSection(model: model)
            Divider()
            ControlsSection(model: model)
            rollup
            Divider()
            Button {
                openWindow(id: "dashboard")
                NSApplication.shared.activate(ignoringOtherApps: true)
            } label: {
                Label("Open Dashboard", systemImage: "macwindow")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 300)
    }

    private var header: some View {
        HStack {
            Image("MenuBarIcon").resizable().frame(width: 16, height: 16)
            Text("Claude Companion").bold()
            Spacer()
            Text("v\(CompanionKit.version) · \(model.status)").font(.caption2).foregroundStyle(.secondary)
        }
    }

    // One-line glance: counts only; the detail is a click away in the dashboard.
    private var rollup: some View {
        let active = model.sessions.filter(\.active).count
        let attention = model.attentionCount
        let remotes = model.remotes.count
        return HStack(spacing: 6) {
            Text("\(active) active").foregroundStyle(.secondary)
            Text("·").foregroundStyle(.tertiary)
            Text("\(attention) need attention")
                .foregroundStyle(attention > 0 ? .orange : .secondary)
            if remotes > 0 {
                Text("·").foregroundStyle(.tertiary)
                Text("\(remotes) remote\(remotes == 1 ? "" : "s")").foregroundStyle(.secondary)
            }
            Spacer()
            if !model.hookInstalled {
                Text("hook off").font(.caption2).foregroundStyle(.red)
            }
        }
        .font(.caption)
    }

    private var footer: some View {
        HStack {
            Button("Refresh") { model.refresh(); model.refreshSessions() }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
        }
    }
}
