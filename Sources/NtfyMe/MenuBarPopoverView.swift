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
    /// Reconnects every server. Global rather than per-server: the popover
    /// can already show several problem servers at once, and a retry button
    /// on each would add more visual weight than a small popover has room
    /// for. `ConnectionCoordinator.reconnectAll()` is what the wiring pass
    /// has ready today; a per-server version is a reasonable future step if
    /// this ever feels too broad, not something this surface needs now.
    let onRetryConnection: () -> Void

    /// Widened from the original 360 and the type scale raised throughout
    /// (title 13pt, body 12pt, nothing below 11pt anywhere) after the
    /// user's own complaint that the popover was "too small, hard to read"
    /// — correct, and mine to own: the first pass was reviewed for
    /// information design and never once checked whether the type was
    /// comfortable at a glance. 400 gives a two-line body and a trailing
    /// timestamp room without either fighting the other; 480 gives the
    /// taller rows that come with the bigger type somewhere to go without
    /// the list feeling cramped immediately.
    static let size = CGSize(width: 400, height: 480)

    /// Local sizes rather than SwiftUI's named text styles
    /// (`.caption`/`.caption2`/`.footnote` are all 10pt on macOS): the type
    /// scale here is a specific, deliberate floor, not "whatever the
    /// closest built-in style happens to be".
    private enum TextSize {
        static let title: CGFloat = 13
        static let body: CGFloat = 12
        static let metadata: CGFloat = 11
    }

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
        // rendering without this line first: the whole popover but for its
        // few fixed-color elements (priority markers, the accent-colored
        // link) went invisible.
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await viewModel.refresh() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "bell")
                .foregroundStyle(.secondary)
            Text("NtfyMe")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            if viewModel.unreadCount > 0 {
                Text("\(viewModel.unreadCount) unread")
                    .font(.system(size: TextSize.metadata))
                    .foregroundStyle(.secondary)
                Button("Mark All Read") { viewModel.markAllAsRead() }
                    .buttonStyle(.plain)
                    .font(.system(size: TextSize.metadata))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("Mark all messages read")
            }
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 10, trailing: 14))
    }

    // MARK: - Connection status

    /// One line ("Connected", "N servers") when everything is fine.
    /// Otherwise expands below the summary into one row per problem server
    /// — name plus `ConnectionState.problemLabel`, e.g. "vaspian-alerts —
    /// Rate limited" — and a Retry affordance when at least one of those
    /// problems is something a retry can plausibly help with. Collapsing
    /// every non-`.open` state to the single word "Disconnected" was the
    /// actual gap: it told the user nothing about which server, why, or
    /// what to do, which is backwards for the state where that information
    /// matters most.
    private var connectionRow: some View {
        let problems = viewModel.problemServers
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle()
                    .fill(summaryColor)
                    .frame(width: 8, height: 8)
                Text(viewModel.connectivity.statusText)
                    .font(.system(size: TextSize.body))
                if problems.isEmpty, viewModel.serverStatuses.count > 1 {
                    Text("· \(viewModel.serverStatuses.count) servers")
                        .font(.system(size: TextSize.metadata))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if viewModel.canRetryConnection {
                    Button("Retry") { onRetryConnection() }
                        .buttonStyle(.plain)
                        .font(.system(size: TextSize.body))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityLabel("Retry connecting now")
                }
            }
            ForEach(problems) { status in
                HStack(spacing: 6) {
                    Circle()
                        .fill(dotColor(for: status.state))
                        .frame(width: 6, height: 6)
                    Text(status.name)
                        .font(.system(size: TextSize.metadata))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(status.state.problemLabel ?? "")
                        .font(.system(size: TextSize.metadata))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.leading, 14)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(connectionAccessibilityLabel(problems: problems))
    }

    private var summaryColor: Color {
        switch viewModel.connectivity {
        case .noServers, .connecting: .secondary
        case .allConnected: .green
        case .someConnected: .yellow
        case .disconnected, .needsAttention: .red
        }
    }

    private func dotColor(for state: ConnectionState) -> Color {
        switch state {
        case .open: .green
        case .idle, .connecting: .secondary
        case .unauthorized: .red
        case .degraded, .backoff: .orange
        }
    }

    private func connectionAccessibilityLabel(problems: [MenuBarServerStatus]) -> String {
        var label = "Connection status: \(viewModel.connectivity.statusText)."
        for status in problems {
            label += " \(status.name): \(status.state.problemLabel ?? "unknown")."
        }
        if viewModel.canRetryConnection {
            label += " Retry available."
        }
        return label
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search recent messages", text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: TextSize.title))
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
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
        .padding(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
    }

    /// A subtle inset ground, not just floating text between the search
    /// field and the first topic group — without it this read as stray text
    /// rather than a banner (seen directly in the rendered popover).
    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.system(size: TextSize.body))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
            .padding(EdgeInsets(top: 0, leading: 14, bottom: 8, trailing: 14))
    }

    // MARK: - Messages

    private var messageList: some View {
        Group {
            if viewModel.filteredGroups.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(viewModel.filteredGroups) { group in
                            topicSection(group)
                        }
                    }
                    .padding(.vertical, 6)
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
                .font(.system(size: TextSize.title))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            if viewModel.searchText.isEmpty {
                Text("New messages appear here as they arrive.")
                    .font(.system(size: TextSize.body))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func topicSection(_ group: MenuBarTopicGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(viewModel.serverName(for: group.serverID).map { "\(group.topic) — \($0)" } ?? group.topic)
                .font(.system(size: TextSize.metadata, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
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
            HStack(alignment: .top, spacing: 8) {
                unreadMarker(isRead: message.isRead)
                    .padding(.top, 6)
                VStack(alignment: .leading, spacing: 3) {
                    if let title = message.title, !title.isEmpty {
                        titleText(title, message: message)
                        Text(message.previewText)
                            .font(.system(size: TextSize.body))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    } else {
                        // No title: repeating the topic name here would just
                        // duplicate the group header immediately above this
                        // row (seen directly in the rendered popover — an
                        // "alerts" row under the "alerts — Home Lab"
                        // header). The body becomes the one primary line
                        // instead, at the weight a title would have used.
                        titleText(message.previewText, message: message)
                    }
                }
                Spacer(minLength: 4)
                Text(relativeTime(message.time))
                    .font(.system(size: TextSize.metadata))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(for: message))
    }

    /// The title line, with an inline priority marker ("‼", the same glyph
    /// the main window uses) appended for priority 4-5 — never a separate
    /// row, so a message with no elevated priority costs nothing extra.
    /// Built via `Text` interpolation (`Text("\(base) \(marker)")`) rather
    /// than the `+` concatenation operator, which macOS 26 deprecates in
    /// favor of exactly this — interpolating an already-styled `Text` keeps
    /// its own font/color, the same as `+` did. That per-segment styling
    /// only survives modifiers applied to `base`/`markerText` *before* the
    /// interpolation, though: `.font`/`.lineLimit` below are safe since
    /// `Text` has no per-character concept of either, but a
    /// `.foregroundStyle` added to `combined` after this point would paint
    /// both the title and the "‼" marker the same color, the same trap `+`
    /// had.
    private func titleText(_ text: String, message: MessageSnapshot) -> some View {
        let weight: Font.Weight = message.isRead ? .regular : .semibold
        let color: Color = receded(message.resolvedPriority) ? .secondary : .primary
        let base = Text(text).foregroundStyle(color)
        let combined: Text
        if let marker = priorityMarker(message.resolvedPriority) {
            let markerText = Text(marker.text).foregroundStyle(marker.color)
            combined = Text("\(base) \(markerText)")
        } else {
            combined = base
        }
        return combined
            .font(.system(size: TextSize.title, weight: weight))
            .lineLimit(1)
            .truncationMode(.tail)
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

    /// Gutter marker: an accent-colored dot for an unread row, matching the
    /// main window's own unread treatment — priority used to live here as a
    /// colored dot, but that put two different signals (read state,
    /// priority) on the same mark. `titleText` carries priority now, as its
    /// own inline "‼" glyph, the same split the main window uses. `.clear`
    /// rather than omitting the view entirely: every row keeps the same
    /// leading inset whether or not it draws anything, so titles don't
    /// shift left when a row is read.
    private func unreadMarker(isRead: Bool) -> some View {
        Circle()
            .fill(isRead ? Color.clear : Color.accentColor)
            .frame(width: 8, height: 8)
    }

    /// `nil` below priority 4 — most messages carry no marker at all, the
    /// same as the main window. High and max both use "‼" (matching the
    /// main window's own glyph); the color still separates them, since nothing
    /// forces "the same marker" to mean "the same color" and the distinction
    /// is useful.
    private func priorityMarker(_ priority: NtfyPriority) -> (text: String, color: Color)? {
        switch priority {
        case .min, .low, .default: nil
        case .high: ("‼", .orange)
        case .max: ("‼", .red)
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
        .font(.system(size: TextSize.body))
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 12, trailing: 12))
    }
}
