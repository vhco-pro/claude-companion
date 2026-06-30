import CompanionKit
import SwiftUI

// Remote-SSH hosts management, extracted from PanelView (plan 12, P1). Lives in the dashboard's
// Remotes tab. The reload reminder is shown here (and, while fresh, summarized in the popover).

struct RemotesPanel: View {
    @Bindable var model: AppModel
    @State private var newRemoteAlias = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let host = model.reloadReminderHost { reloadBanner(host) }
            if model.remotes.isEmpty {
                Text("No remote hosts. Add one below to gate Claude Code over VSCode Remote-SSH.")
                    .font(.caption).foregroundStyle(.tertiary)
            } else {
                ForEach(model.remotes) { r in remoteRow(r) }
            }
            Divider()
            addRemoteRow
        }
    }

    private func reloadBanner(_ host: String) -> some View {
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
}
