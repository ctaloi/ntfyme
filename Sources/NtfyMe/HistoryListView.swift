import SwiftUI
import NtfyKit

/// The list column: search, priority/tag/date filters, and the page of
/// messages the current scope and filters resolve to.
struct HistoryListView: View {
    @Bindable var viewModel: HistoryViewModel
    @State private var dateRangePopoverShown = false
    @State private var customSince: Date = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var customUntil: Date = Date()

    var body: some View {
        content
            .searchable(text: $viewModel.searchText, placement: .toolbar, prompt: "Search title or body")
            .toolbar {
                ToolbarItemGroup {
                    priorityMenu
                    dateRangeMenu
                    tagField
                }
            }
            .navigationTitle(scopeTitle)
    }

    private var content: some View {
        VStack(spacing: 0) {
            if let actionError = viewModel.actionErrorMessage {
                actionErrorBanner(actionError)
            }
            mainContent
        }
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
            HistoryStatusView(systemImage: "tray", title: "No Messages",
                              message: "Nothing matches the current filters.")
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

    private var priorityMenu: some View {
        Menu {
            Picker("Priority", selection: $viewModel.priorityFilter) {
                ForEach(PriorityFilter.allCases) { filter in
                    Text(filter.label).tag(filter)
                }
            }
        } label: {
            Label("Priority", systemImage: "flag")
        }
        .help("Filter by priority")
        .accessibilityLabel(Text("Priority filter: \(viewModel.priorityFilter.label)"))
    }

    private var tagField: some View {
        TextField("Tag", text: $viewModel.tagFilter)
            .textFieldStyle(.roundedBorder)
            .frame(width: 100)
            .accessibilityLabel(Text("Filter by tag"))
    }

    private var dateRangeMenu: some View {
        Menu {
            Button("Any Time") { viewModel.dateRangeFilter = .any }
            Button("Today") { viewModel.dateRangeFilter = .today }
            Button("Last 7 Days") { viewModel.dateRangeFilter = .last7Days }
            Button("Last 30 Days") { viewModel.dateRangeFilter = .last30Days }
            Divider()
            Button("Custom Range…") { dateRangePopoverShown = true }
        } label: {
            Label(viewModel.dateRangeFilter.label, systemImage: "calendar")
        }
        .help("Filter by date range")
        .accessibilityLabel(Text("Date range filter: \(viewModel.dateRangeFilter.label)"))
        .popover(isPresented: $dateRangePopoverShown) {
            VStack(alignment: .leading, spacing: 12) {
                DatePicker("From", selection: $customSince, displayedComponents: .date)
                DatePicker("To", selection: $customUntil, displayedComponents: .date)
                Button("Apply") {
                    viewModel.dateRangeFilter = .custom(since: customSince, until: customUntil)
                    dateRangePopoverShown = false
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
            .frame(width: 220)
        }
    }

    private var scopeTitle: String {
        switch viewModel.scope {
        case .all: return "All Messages"
        case .server(let id): return viewModel.servers.first(where: { $0.id == id })?.name ?? "Server"
        case .topic(_, let topic): return topic
        }
    }
}

/// One row: read/unread indicator, priority, title/body preview, timestamp.
private struct HistoryRow: View {
    let snapshot: MessageSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(snapshot.isRead ? Color.clear : Color.accentColor)
                .frame(width: 7, height: 7)
                .padding(.top, 5)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(snapshot.title?.isEmpty == false ? snapshot.title! : snapshot.topic)
                        .font(.headline)
                        .fontWeight(snapshot.isRead ? .regular : .semibold)
                        .lineLimit(1)
                    Spacer()
                    PriorityPill(priority: snapshot.resolvedPriority)
                    Text(snapshot.time, style: .time)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(snapshot.body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if !snapshot.tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(snapshot.tags, id: \.self) { TagChip(tag: $0) }
                        }
                    }
                    .fadedTrailingEdge()
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilitySummary))
    }

    private var accessibilitySummary: String {
        let title = snapshot.title?.isEmpty == false ? snapshot.title! : snapshot.topic
        let readState = snapshot.isRead ? "read" : "unread"
        return "\(title), \(readState), priority \(snapshot.resolvedPriority.label)"
    }
}
