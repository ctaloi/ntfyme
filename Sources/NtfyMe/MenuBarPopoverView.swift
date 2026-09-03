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
    /// A row tap opens the app (History, scrolled to that message), not the
    /// message's `click` URL — keyed on `MessageSnapshot.id`, the unique key
    /// the wiring pass's reveal-by-key API takes, so this view hands out
    /// exactly what that API needs rather than the whole snapshot. See
    /// `messageRow`'s doc comment for why `click` no longer has a row-tap
    /// path at all.
    let onOpenMessage: (String) -> Void

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
        // An `NSPopover` normally supplies its own opaque content background,
        // but nothing else in this view does — every other color here is a
        // dynamic system color (`.primary`, `.secondary`, `Divider`) that
        // resolves to a *light* value under `.dark`. Without an explicit,
        // equally dynamic background behind it, dark mode has light text
        // over whatever backing happens to be there, which in an offscreen
        // render (`MenuBarSnapshotTests`) is nothing at all — confirmed by
        // rendering without this line first: the whole popover but for the
        // priority dots and the accent-colored link went invisible.
        .background(Color(nsColor: .windowBackgroundColor))
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

    /// A tap marks the row read and opens the app to that message — never
    /// the message's `click` URL, even when one is set. That URL used to be
    /// opened here (through `NtfyURLPolicy`, since `click` is
    /// attacker-controlled — spec §9 — and a bare `URL(string:)` would let a
    /// `file://` or custom-scheme value read a local file or launch another
    /// app), but a row that sometimes opens a browser and sometimes opens a
    /// window is exactly the kind of inconsistent control that erodes trust
    /// in what a tap will do. The History detail pane's own "open click URL"
    /// action button is the deliberate, visible place for that now — still
    /// routed through `NtfyURLPolicy` there, since the message is the same
    /// attacker-controlled content wherever it is opened from.
    private func messageRow(_ message: MessageSnapshot) -> some View {
        Button {
            viewModel.markRead(message)
            onOpenMessage(message.id)
        } label: {
            HStack(alignment: .top, spacing: 6) {
                priorityDot(message.resolvedPriority)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 1) {
                    if let title = message.title, !title.isEmpty {
                        Text(title)
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
                    } else {
                        // No title: repeating the topic name here would just
                        // duplicate the group header immediately above this
                        // row (seen directly in the rendered popover — an
                        // "alerts" row under the "alerts — Home Lab"
                        // header). The body becomes the one primary line
                        // instead, at the weight a title would have used.
                        Text(message.body)
                            .font(.subheadline)
                            .fontWeight(message.isRead ? .regular : .semibold)
                            .foregroundStyle(receded(message.resolvedPriority) ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 4)
                Text(relativeTime(message.time))
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

    /// `Text(_:style:.relative)` was tried first and rejected: in a row this
    /// narrow it renders as "2 min, 0 sec" / "1 hr, 0 min" rather than a
    /// compact "2m" / "1h" — seen directly in `MenuBarSnapshotTests`'
    /// populated render, not just suspected. `DateComponentsFormatter` with
    /// one allowed unit gives the compact form at the cost of not
    /// live-updating between renders — acceptable here since the popover's
    /// own data refresh (`MenuBarViewModel.refresh()`) is what keeps this
    /// current, the same as every other value in this row.
    private static let relativeTimeFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.zeroFormattingBehavior = .dropAll
        return formatter
    }()

    private func relativeTime(_ date: Date) -> String {
        Self.relativeTimeFormatter.string(from: date, to: Date()) ?? ""
    }

    private func accessibilityLabel(for message: MessageSnapshot) -> String {
        let readState = message.isRead ? "" : "Unread. "
        // Matches the row's own title/body collapse just above: an untitled
        // message reads as just its body, not body prefixed with the topic
        // name a second time.
        guard let title = message.title, !title.isEmpty else {
            return "\(readState)\(message.body)"
        }
        return "\(readState)\(title). \(message.body)"
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
        // `spacing: 16`, not the label's own icon-to-title gap (~4-6pt): with
        // the same spacing on both, History and Settings read as one run-on
        // control rather than two — seen directly in the rendered popover.
        HStack(spacing: 16) {
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
