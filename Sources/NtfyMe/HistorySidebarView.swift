import SwiftUI
import NtfyKit

/// The sidebar column: "All Messages", then each server with its topics.
struct HistorySidebarView: View {
    @Bindable var viewModel: HistoryViewModel
    /// Defaults every server open — a server row with no `Bool` recorded
    /// here yet reads as expanded, matching the initial layout before the
    /// user collapses anything.
    @State private var collapsedServers: Set<UUID> = []

    var body: some View {
        List(selection: Binding(
            get: { viewModel.scope },
            set: { newValue in if let newValue { viewModel.scope = newValue } })
        ) {
            Label("All Messages", systemImage: "tray.full")
                .badge(viewModel.allUnreadCount)
                .tag(HistoryScope.all)
                .accessibilityLabel(Text("All Messages, \(viewModel.allUnreadCount) unread"))

            ForEach(viewModel.servers) { server in
                // The server row itself is selectable (`.server(id)`, its own
                // status dot and unread badge) — spec §7 asks for both, which
                // a plain `Section` header cannot carry, since a header is
                // not a selectable row.
                DisclosureGroup(isExpanded: isExpandedBinding(for: server.id)) {
                    ForEach(topicsFor(server)) { topic in
                        topicRow(topic)
                    }
                } label: {
                    serverRow(server)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("History")
        .frame(minWidth: 200)
    }

    private func isExpandedBinding(for serverID: UUID) -> Binding<Bool> {
        Binding(
            get: { !collapsedServers.contains(serverID) },
            set: { expanded in
                if expanded { collapsedServers.remove(serverID) } else { collapsedServers.insert(serverID) }
            })
    }

    private func topicsFor(_ server: ServerRecordSnapshot) -> [TopicSummary] {
        viewModel.topics.filter { $0.serverID == server.id }
    }

    private func serverUnreadCount(_ server: ServerRecordSnapshot) -> Int {
        topicsFor(server).reduce(0) { $0 + $1.unreadCount }
    }

    private func serverRow(_ server: ServerRecordSnapshot) -> some View {
        let status = viewModel.statusProvider(server.id)
        return Label {
            Text(server.name)
        } icon: {
            Image(systemName: status.symbolName)
                .font(.system(size: 8))
                .foregroundStyle(statusColor(status))
        }
        .badge(serverUnreadCount(server))
        .tag(HistoryScope.server(server.id))
        .contextMenu {
            Button("Mark All Read") {
                Task { await viewModel.markAllRead(in: .server(server.id)) }
            }
        }
        .accessibilityLabel(Text("\(server.name), \(status.accessibilityLabel), \(serverUnreadCount(server)) unread"))
    }

    private func statusColor(_ status: HistoryConnectionStatus) -> Color {
        switch status {
        case .unknown, .connecting: return .secondary
        case .connected: return .green
        case .disconnected: return .red
        }
    }

    private func topicRow(_ topic: TopicSummary) -> some View {
        let scope = HistoryScope.topic(serverID: topic.serverID, topic: topic.topic)
        return Label {
            HStack {
                Text(topic.displayName ?? topic.topic)
                if topic.muted {
                    Image(systemName: "bell.slash")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Text("Muted"))
                }
            }
        } icon: {
            Image(systemName: "number")
        }
        .badge(topic.unreadCount)
        .tag(scope)
        .contextMenu {
            Button("Mark All Read") {
                Task { await viewModel.markAllRead(in: scope) }
            }
        }
        .accessibilityLabel(Text("\(topic.displayName ?? topic.topic), \(topic.unreadCount) unread"))
    }
}
