import SwiftUI
import NtfyKit

/// The popover's SwiftUI contents. Everything it needs to act — History,
/// Settings, Quit — arrives as a closure; this view never reaches into
/// another agent's types (`AppDelegate`, `AppGraph`, the History window, the
/// Settings scene) directly.
struct MenuBarPopoverView: View {
    @ObservedObject var viewModel: MenuBarViewModel
    let onOpenHistory: () -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    @Environment(\.openURL) private var openURL

    static let size = CGSize(width: 360, height: 440)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            connectionRow
            Divider()
            searchField
            if let loadErrorMessage = viewModel.loadErrorMessage {
                errorBanner(loadErrorMessage)
            }
            messageList
            Divider()
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .task { await viewModel.refresh() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "bell")
                .foregroundStyle(.secondary)
            Text("NtfyMe")
                .font(.headline)
            Spacer()
            if viewModel.unreadCount > 0 {
                Text("\(viewModel.unreadCount) unread")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Mark All Read") { viewModel.markAllAsRead() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("Mark all messages read")
            }
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 8, trailing: 12))
    }

    // MARK: - Connection status

    private var connectionRow: some View {
        let info = connectivityDisplay
        return HStack(spacing: 6) {
            Circle()
                .fill(info.color)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(info.text)
                    .font(.caption)
                if let detail = info.detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Connection status: \(info.text)\(info.detail.map { ", \($0)" } ?? "")")
    }

    private struct ConnectivityDisplay {
        let text: String
        let detail: String?
        let color: Color
    }

    private var connectivityDisplay: ConnectivityDisplay {
        let statuses = viewModel.serverStatuses
        let connectivity = viewModel.connectivity
        let text = connectivity.statusText
        switch connectivity {
        case .noServers, .connecting, .disconnected:
            return ConnectivityDisplay(text: text, detail: nil,
                                       color: connectivity == .disconnected ? .red : .secondary)
        case .allConnected:
            let detail = statuses.count > 1 ? "\(statuses.count) servers" : nil
            return ConnectivityDisplay(text: text, detail: detail, color: .green)
        case .someConnected:
            let names = statuses.filter { $0.state != .open }.map(\.name)
            return ConnectivityDisplay(text: text,
                                       detail: names.isEmpty ? nil : names.joined(separator: ", "),
                                       color: .yellow)
        case .needsAttention:
            let names = statuses.filter { $0.state == .unauthorized }.map(\.name)
            return ConnectivityDisplay(text: text,
                                       detail: names.isEmpty ? nil : names.joined(separator: ", "),
                                       color: .red)
        }
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search recent messages", text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .accessibilityLabel("Search recent messages")
            if !viewModel.searchText.isEmpty {
                Button { viewModel.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(6)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        .padding(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
    }

    // MARK: - Messages

    private var messageList: some View {
        Group {
            if viewModel.filteredGroups.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(viewModel.filteredGroups) { group in
                            topicSection(group)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: viewModel.searchText.isEmpty ? "tray" : "magnifyingglass")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(viewModel.searchText.isEmpty
                 ? "No messages yet"
                 : "No messages match \u{201C}\(viewModel.searchText)\u{201D}")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            if viewModel.searchText.isEmpty {
                Text("New messages appear here as they arrive.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func topicSection(_ group: MenuBarTopicGroup) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(viewModel.serverName(for: group.serverID).map { "\(group.topic) — \($0)" } ?? group.topic)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .lineLimit(1)
                .truncationMode(.tail)
            ForEach(group.messages) { message in
                messageRow(message)
            }
        }
    }

    private func messageRow(_ message: MessageSnapshot) -> some View {
        Button {
            viewModel.markRead(message)
            if let click = message.click, let url = URL(string: click) {
                openURL(url)
            }
        } label: {
            HStack(alignment: .top, spacing: 6) {
                priorityDot(message.resolvedPriority)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 1) {
                    Text(displayTitle(for: message))
                        .font(.subheadline)
                        .fontWeight(message.isRead ? .regular : .semibold)
                        .foregroundStyle(receded(message.resolvedPriority) ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(message.body)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 4)
                Text(message.time, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(for: message))
    }

    /// `title` falling back to `topic`: ntfy messages may publish with no
    /// title at all, and a blank row header is worse than the topic name.
    private func displayTitle(for message: MessageSnapshot) -> String {
        guard let title = message.title, !title.isEmpty else { return message.topic }
        return title
    }

    private func accessibilityLabel(for message: MessageSnapshot) -> String {
        let readState = message.isRead ? "" : "Unread. "
        return "\(readState)\(displayTitle(for: message)). \(message.body)"
    }

    private func receded(_ priority: NtfyPriority) -> Bool {
        priority == .min || priority == .low
    }

    private func priorityDot(_ priority: NtfyPriority) -> some View {
        Circle()
            .fill(priorityColor(priority))
            .frame(width: 6, height: 6)
    }

    private func priorityColor(_ priority: NtfyPriority) -> Color {
        switch priority {
        case .min, .low, .default: .secondary
        case .high: .orange
        case .max: .red
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 4) {
            Button(action: onOpenHistory) {
                Label("History", systemImage: "clock.arrow.circlepath")
            }
            .accessibilityLabel("Open History")

            Button(action: onOpenSettings) {
                Label("Settings", systemImage: "gearshape")
            }
            .accessibilityLabel("Open Settings")

            Spacer()

            Button(action: onQuit) {
                Label("Quit", systemImage: "power")
            }
            .accessibilityLabel("Quit NtfyMe")
        }
        .buttonStyle(.borderless)
        .labelStyle(.titleAndIcon)
        .font(.callout)
        .padding(EdgeInsets(top: 6, leading: 10, bottom: 10, trailing: 10))
    }
}
