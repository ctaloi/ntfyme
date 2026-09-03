import SwiftUI
import NtfyKit

/// The list column: the page of messages the current scope and filters
/// resolve to, and the window title naming that scope.
///
/// The Filter menu, Mark All Read and the search field used to be declared
/// here and are now on `HistoryView` — a toolbar belongs to the window, and
/// declaring it on a column made its items move whenever a column did. See
/// that file's doc comment for the three bugs that came from it.
struct HistoryListView: View {
    @Bindable var viewModel: HistoryViewModel

    var body: some View {
        content
            .navigationTitle(scopeTitle)
    }

    private var content: some View {
        VStack(spacing: 0) {
            if let actionError = viewModel.actionErrorMessage {
                actionErrorBanner(actionError)
            }
            mainContent
        }
        // `List` (the `list` branch of `mainContent`) paints its own opaque
        // background, so this was never visible there — but the
        // loading/error/empty branches are a small centered
        // `HistoryStatusView` with nothing behind it. Same bug as
        // `HistoryDetailView`'s empty-selection state, found the same way:
        // `meanAlpha` on `history-empty.png` measured 0.35 against a 0.85
        // floor. `maxWidth`/`maxHeight: .infinity` first, so the background
        // actually covers the full column regardless of which branch is
        // showing, not just the centered placeholder's own small size.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// A mutation failing (mark read, delete, …) must not blank a list of
    /// perfectly good messages — only the initial search failing, with
    /// nothing else to show, gets the full-pane error state below.
    @ViewBuilder
    private var mainContent: some View {
        if let searchError = viewModel.searchErrorMessage, viewModel.messages.isEmpty {
            HistoryStatusView(systemImage: "exclamationmark.triangle", title: "Couldn't Load Messages",
                              message: searchError)
        } else if viewModel.isLoading && viewModel.messages.isEmpty {
            HistoryStatusView(systemImage: "hourglass", title: "Loading…", message: nil)
        } else if viewModel.messages.isEmpty {
            // Two different causes for the same empty page, that want
            // different words: nothing has ever arrived, or the scope/
            // filters exclude everything that has. Telling a brand-new
            // user with no filters set that their (nonexistent) filters
            // are hiding messages sends them hunting for a control that
            // was never the problem — see `archiveIsEmpty`'s doc comment.
            if viewModel.archiveIsEmpty && !viewModel.hasActiveFilters {
                if viewModel.servers.isEmpty {
                    HistoryStatusView(systemImage: "server.rack", title: "No Servers Configured",
                                      message: "Add a server in Settings to start receiving messages.")
                } else {
                    HistoryStatusView(systemImage: "tray", title: "No Messages Yet",
                                      message: "New messages appear here as they arrive.")
                }
            } else {
                HistoryStatusView(systemImage: "line.3.horizontal.decrease.circle", title: "No Messages",
                                  message: "Nothing matches the current filters.") {
                    Button("Clear Filters") { viewModel.clearFilters() }
                }
            }
        } else {
            list
        }
    }

    private func actionErrorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
            Spacer()
            Button {
                viewModel.dismissActionError()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(Text("Dismiss error"))
        }
        .padding(8)
        .background(Color.orange.opacity(0.12))
    }

    private var list: some View {
        // `ScrollViewReader` + the `onChange` below is what makes
        // `HistoryViewModel.reveal(messageKey:)` actually visible rather
        // than merely selected: setting `selection` alone does not scroll
        // `List` to the newly-selected row. The same `onChange` is also
        // where "viewing marks read" lives (`markSelectedRead()`) — tied to
        // the list's own selection change rather than to `selection`'s
        // setter, so the view model method stays a plain, directly
        // testable `async func` instead of a fire-and-forget side effect
        // hidden inside a property observer.
        ScrollViewReader { proxy in
            List(selection: $viewModel.selection) {
                ForEach(viewModel.messages) { snapshot in
                    HistoryRow(snapshot: snapshot)
                        .tag(snapshot.id)
                        .onAppear { Task { await viewModel.loadMoreIfNeeded(currentItem: snapshot) } }
                        .contextMenu { contextMenu(for: snapshot) }
                }
                if viewModel.isLoadingMore {
                    HStack {
                        Spacer()
                        ProgressView()
                            .accessibilityLabel(Text("Loading more messages"))
                        Spacer()
                    }
                }
            }
            .listStyle(.inset)
            .frame(minWidth: 280)
            .onChange(of: viewModel.selection) { _, newSelection in
                guard newSelection.count == 1, let target = newSelection.first else { return }
                withAnimation {
                    proxy.scrollTo(target, anchor: .center)
                }
                Task { await viewModel.markSelectedRead() }
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for snapshot: MessageSnapshot) -> some View {
        let targets = viewModel.actionTargets(for: snapshot)
        let allRead = targets.allSatisfy(\.isRead)
        Button(allRead ? "Mark as Unread" : "Mark as Read") {
            Task { await viewModel.markRead(targets, read: !allRead) }
        }
        Button("Copy") { viewModel.copy(targets) }
        if targets.count == 1, targets[0].click != nil {
            Button("Open Link") { viewModel.openClickURL(targets[0]) }
        }
        Divider()
        Button("Delete", role: .destructive) {
            Task { await viewModel.delete(targets) }
        }
    }

    /// One grouped menu replacing the three loose toolbar capsules — unread,
    /// priority, and date range as submenus/toggle, tag as a free-text field
    /// at the bottom. The icon fills when any of the four is active, the
    /// same "something is filtering this view" affordance `hasActiveFilters`
    /// already drives for the empty state's wording.
    private var scopeTitle: String {
        switch viewModel.scope {
        case .all: return "All Messages"
        case .unread: return "Unread"
        case .topic(_, let topic): return topic
        }
    }
}

/// One row: an accent dot for unread in the gutter, title/time on one
/// line, a two-line body preview, and topic plus a quiet priority marker
/// (only for priority 4-5, matching how quietly priority is meant to read)
/// on their own line beneath — the mockup's design, replacing the previous
/// cramped single-line-title-plus-pill layout.
private struct HistoryRow: View {
    let snapshot: MessageSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(snapshot.isRead ? Color.clear : Color.accentColor)
                .frame(width: 7, height: 7)
                .padding(.top, 5)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(titleText)
                        .font(.system(size: 13, weight: snapshot.isRead ? .regular : .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(snapshot.time, style: .time)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                // `previewText`, not `body`: a markdown message previewed
                // as its own source is the raw-markup bug this row had.
                Text(snapshot.previewText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 5) {
                    // A long topic name must truncate on one line, not wrap
                    // — found in `history-long-content.png`: without this,
                    // a long topic pushed the priority marker down onto its
                    // own line and made one row taller than its neighbors.
                    // Same rule the sidebar and detail pane already apply.
                    Text(snapshot.topic)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if snapshot.priority >= NtfyPriority.high.rawValue {
                        Image(systemName: "exclamationmark.2")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(snapshot.priority >= NtfyPriority.max.rawValue ? .red : .orange)
                            .fixedSize()
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilitySummary))
    }

    /// Emoji tags lead the title here exactly as they do in the banner —
    /// same `NtfyEmoji.prefixed` call, so the row and the notification for
    /// one message cannot read differently.
    private var titleText: String {
        let base = snapshot.title?.isEmpty == false ? snapshot.title! : snapshot.topic
        return NtfyEmoji.prefixed(base, tags: snapshot.tags)
    }

    private var accessibilitySummary: String {
        let readState = snapshot.isRead ? "read" : "unread"
        return "\(titleText), \(readState), priority \(snapshot.resolvedPriority.label)"
    }
}
