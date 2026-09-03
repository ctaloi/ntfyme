import SwiftUI
import NtfyKit

/// The sidebar column: "All Messages" and "Unread" as smart views, then each
/// server as a plain, non-selectable section header grouping its topics —
/// matching the approved redesign mockup (`RedesignMockups.swift`). A
/// server used to be its own selectable `HistoryScope`, with a `Section`
/// replaced by a hand-rolled `DisclosureGroup` so the header could carry a
/// tag; the mockup drops server-level selection entirely, which means a
/// plain `Section` is not just simpler but correct again — and it gets the
/// native macOS sidebar disclosure chevron for free, where the
/// `DisclosureGroup` version had to reimplement collapse state by hand.
struct HistorySidebarView: View {
    @Bindable var viewModel: HistoryViewModel

    var body: some View {
        List(selection: Binding(
            get: { viewModel.scope },
            set: { newValue in if let newValue { viewModel.scope = newValue } })
        ) {
            Section {
                Label("All Messages", systemImage: "tray.full")
                    .badge(viewModel.allUnreadCount)
                    .tag(HistoryScope.all)
                    .accessibilityLabel(Text("All Messages, \(viewModel.allUnreadCount) unread"))

                // No badge, deliberately, where "All Messages" above has
                // one: both were showing `allUnreadCount`, so the sidebar
                // displayed the same number twice in adjacent rows. On the
                // Unread view the badge is also the length of the list the
                // user is looking at, which is the least useful place to
                // put a count. The accessibility label still says it, since
                // a screen reader cannot see the list.
                Label("Unread", systemImage: "circle.inset.filled")
                    .tag(HistoryScope.unread)
                    .accessibilityLabel(Text("Unread, \(viewModel.allUnreadCount) messages"))
            }

            ForEach(viewModel.servers) { server in
                Section {
                    ForEach(topicsFor(server)) { topic in
                        topicRow(topic)
                    }
                } header: {
                    serverHeader(server)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("History")
        .frame(minWidth: 200)
    }

    private func topicsFor(_ server: ServerRecordSnapshot) -> [TopicSummary] {
        viewModel.topics.filter { $0.serverID == server.id }
    }

    /// A plain text header per the mockup, plus a small status dot the
    /// mockup's static content has no way to depict (it hardcodes no
    /// connection state at all) but that `AppDelegate` already wires
    /// (`setStatusProvider`) — dropping it here would make that wiring
    /// silently pointless rather than merely unused.
    private func serverHeader(_ server: ServerRecordSnapshot) -> some View {
        let status = viewModel.statusProvider(server.id)
        return HStack(spacing: 5) {
            Image(systemName: status.symbolName)
                .font(.system(size: 7))
                .foregroundStyle(statusColor(status))
                .accessibilityLabel(Text(status.accessibilityLabel))
            Text(server.name)
        }
        .contextMenu {
            Button("Mark All Read") {
                Task { await viewModel.markAllRead(serverID: server.id, topic: nil) }
            }
        }
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
            HStack(spacing: 6) {
                Text(topic.displayName ?? topic.topic).lineLimit(1)
                if topic.muted {
                    Image(systemName: "bell.slash.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
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
                Task { await viewModel.markAllRead(serverID: topic.serverID, topic: topic.topic) }
            }
        }
        .accessibilityLabel(Text("\(topic.displayName ?? topic.topic), \(topic.unreadCount) unread"))
    }
}
