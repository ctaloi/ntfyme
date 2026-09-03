import SwiftUI
import NtfyKit

/// The sidebar column: smart views, then subscriptions — flat when one
/// server is the whole world, grouped under per-server sections when
/// servers are plural — plus a sort control pinned at the bottom.
///
/// **This is a native `List` with `.listStyle(.sidebar)`, on purpose.** An
/// experiment replaced it with hand-rolled rows to support folder drag and
/// drop (whose row gestures a `List` defeats); the folders are gone now,
/// and with them the only reason to give up what the system sidebar gives
/// for free: the selection pill, vibrancy, spacing rhythm, and keyboard
/// navigation that made this column look right in the first place. Every
/// custom approximation was measured against it and lost.
///
/// No folders, likewise on purpose: one server and a dozen topics wants
/// *sorting*, not grouping — the sort control at the bottom is the feature.
/// Servers stay non-selectable section headers (naming the only server
/// that exists for the one-server majority is noise, so single-server
/// installs get a flat list).
struct HistorySidebarView: View {
    @Bindable var viewModel: HistoryViewModel
    /// Opens Compose prefilled with a topic's destination (see `ComposeSeed`)
    /// — the same affordance the message list's context menu has, from the
    /// place that *lists* topics rather than messages.
    var onComposeToTopic: (ComposeSeed) -> Void = { _ in }

    /// The sidebar's topic order, persisted. Three answers to "how do I
    /// find my topic" — alphabetical, by what needs me, by what happened
    /// last. Defaults to name, which is what the store already delivers.
    @AppStorage("sidebar.topicSort") private var sortRaw = SidebarSort.name.rawValue

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

                // No badge here where "All Messages" above has one: both
                // showed the same number, twice, in adjacent rows. The
                // accessibility label still says it, since a screen reader
                // cannot see the list.
                Label("Unread", systemImage: "envelope.badge")
                    .tag(HistoryScope.unread)
                    .accessibilityLabel(Text("Unread, \(viewModel.allUnreadCount) messages"))
            }

            if viewModel.showsServerHeaders {
                ForEach(unfiledServerSections) { section in
                    Section(header: serverHeader(section.server)) {
                        ForEach(sorted(section.topics)) { topic in
                            topicRow(topic)
                        }
                    }
                }
            } else {
                Section {
                    ForEach(sorted(viewModel.topics)) { topic in
                        topicRow(topic)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("History")
        // Pinned above the safe area so it rides on the sidebar's own
        // material — the spot Notes and Reminders use for exactly this
        // control.
        .safeAreaInset(edge: .bottom) { sortFooter }
    }

    // MARK: - Sorting

    enum SidebarSort: String, CaseIterable, Identifiable {
        case name, unread, recent

        var id: String { rawValue }

        var label: String {
            switch self {
            case .name: "Name"
            case .unread: "Unread"
            case .recent: "Recent"
            }
        }

        var help: String {
            switch self {
            case .name: "Alphabetical"
            case .unread: "Most unread first"
            case .recent: "Most recent message first"
            }
        }
    }

    private var sort: SidebarSort {
        SidebarSort(rawValue: sortRaw) ?? .name
    }

    /// Orders a topic list by the chosen sort. Name is the store's own
    /// order (it arrives sorted); unread is a count desc; recent puts the
    /// topic with the newest last message first, topics that have never
    /// received anything last. Name breaks every tie, so the order never
    /// reshuffles between refreshes.
    private func sorted(_ topics: [TopicSummary]) -> [TopicSummary] {
        switch sort {
        case .name:
            return topics.sorted { $0.topic < $1.topic }
        case .unread:
            return topics.sorted {
                if $0.unreadCount != $1.unreadCount { return $0.unreadCount > $1.unreadCount }
                return $0.topic < $1.topic
            }
        case .recent:
            return topics.sorted {
                switch ($0.lastMessageTime, $1.lastMessageTime) {
                case (nil, nil): return $0.topic < $1.topic
                case (nil, _): return false
                case (_, nil): return true
                case (let a?, let b?):
                    if a != b { return a > b }
                    return $0.topic < $1.topic
                }
            }
        }
    }

    /// The sort control: one quiet menu naming the current order, with a
    /// checkmark list to change it. Inline `Picker` inside the menu is what
    /// gives the checkmark.
    private var sortFooter: some View {
        HStack {
            Menu {
                Picker("Sort Topics By", selection: Binding(
                    get: { sort },
                    set: { sortRaw = $0.rawValue })) {
                    ForEach(SidebarSort.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Sort: \(sort.label)", systemImage: "arrow.up.arrow.down")
                    .font(.system(size: 11, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(sort.help)
            .accessibilityLabel(Text("Sort topics: \(sort.label)"))
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Server sections

    /// One unfiled group: the topics a server contributes to the sidebar.
    /// A struct, not a tuple — `ForEach` needs the identity.
    private struct UnfiledSection: Identifiable {
        let server: ServerRecordSnapshot
        let topics: [TopicSummary]
        var id: UUID { server.id }
    }

    /// Topics grouped per server, in the store's own server order. Empty
    /// servers contribute nothing.
    private var unfiledServerSections: [UnfiledSection] {
        viewModel.servers.compactMap { server in
            let filed = viewModel.topics.filter { $0.serverID == server.id }
            return filed.isEmpty ? nil : UnfiledSection(server: server, topics: filed)
        }
    }

    /// A plain text section header naming the server, plus the connection
    /// status dot the wiring pass supplies — a header is a caption, not a
    /// control, so it carries no chevron and no selection.
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

    // MARK: - Topic rows

    private func topicRow(_ topic: TopicSummary) -> some View {
        let scope = HistoryScope.topic(serverID: topic.serverID, topic: topic.topic)
        let hasUnread = topic.unreadCount > 0
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
            // The `#` does double duty as the unread tell: accent while a
            // topic has unread mail, secondary once it is all read — so a
            // glance down the sidebar shows *where* the live traffic is,
            // the same job the badge count does, in the same colour.
            Image(systemName: "number")
                .font(.system(size: 11, weight: hasUnread ? .semibold : .regular))
                .foregroundStyle(hasUnread ? Color.accentColor : Color.secondary)
        }
        .badge(topic.unreadCount)
        .tag(scope)
        .contextMenu {
            Button("Mark All Read") {
                Task { await viewModel.markAllRead(serverID: topic.serverID, topic: topic.topic) }
            }
            Button("New Message to This Topic", systemImage: "paperplane") {
                onComposeToTopic(ComposeSeed(serverID: topic.serverID, topic: topic.topic))
            }
        }
        .accessibilityLabel(Text("\(topic.displayName ?? topic.topic), \(topic.unreadCount) unread"))
    }

    private func statusColor(_ status: HistoryConnectionStatus) -> Color {
        switch status {
        case .unknown, .connecting: return .secondary
        case .connected: return .green
        case .disconnected: return .red
        }
    }
}
