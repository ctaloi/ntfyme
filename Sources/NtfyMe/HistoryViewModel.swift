import AppKit
import Foundation
import Observation
import NtfyKit

/// Drives the History window's three columns.
///
/// Owns no persistence itself — every read and write goes through
/// `MessageStore`, which is `Sendable` and safe to call from `@MainActor`
/// here. `messages` holds only the currently loaded page(s); paging happens
/// via `offset`/`limit`, never a full-archive fetch (spec: "paging and
/// search performance matter").
@MainActor
@Observable
final class HistoryViewModel {
    static let pageSize = 200
    /// How long a keystroke in the search field or the tag field waits
    /// before it becomes a query. `search` pushes every filter but `tag` to
    /// SQL; a `tag` filter fetches every SQL-matching row unpaged and
    /// filters in Swift, so debouncing both text fields is what keeps a
    /// keystroke from firing that path on every character.
    private static let debounceDelay: Duration = .milliseconds(300)

    private let store: MessageStore

    // MARK: Sidebar
    private(set) var servers: [ServerRecordSnapshot] = []
    private(set) var topics: [TopicSummary] = []
    private(set) var allUnreadCount: Int = 0
    var scope: HistoryScope = .all {
        didSet {
            guard oldValue != scope else { return }
            selection = []
            Task { await refreshMessages() }
        }
    }
    /// Backed by nothing today (see `HistoryConnectionStatus`'s doc comment);
    /// a wiring pass replaces this closure with one backed by
    /// `ConnectionCoordinator`.
    var statusProvider: (UUID) -> HistoryConnectionStatus = { _ in .unknown }

    // MARK: List / filters
    var searchText: String = "" {
        didSet {
            guard oldValue != searchText else { return }
            scheduleDebouncedRefresh()
        }
    }
    var tagFilter: String = "" {
        didSet {
            guard oldValue != tagFilter else { return }
            scheduleDebouncedRefresh()
        }
    }
    var priorityFilter: PriorityFilter = .any {
        didSet {
            guard oldValue != priorityFilter else { return }
            Task { await refreshMessages() }
        }
    }
    var dateRangeFilter: DateRangeFilter = .any {
        didSet {
            guard oldValue != dateRangeFilter else { return }
            Task { await refreshMessages() }
        }
    }

    private(set) var messages: [MessageSnapshot] = []
    var selection: Set<String> = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var canLoadMore = true
    /// Set only when the initial fetch for the current scope/filters comes
    /// back empty because it *failed*, not because nothing matches. Gates a
    /// full-pane error state in the list — required so a failed search reads
    /// as "search failed", never as the visually identical "no messages"
    /// empty state.
    private(set) var searchErrorMessage: String?
    /// Set when a mutation (`markRead`, `delete`, `markAllRead`) or the
    /// sidebar load fails. Rendered as a dismissible banner above whatever
    /// `messages` already holds — those rows are still good and must not be
    /// blanked by an unrelated action failing.
    private(set) var actionErrorMessage: String?
    private var nextOffset = 0
    private var debounceTask: Task<Void, Never>?

    init(store: MessageStore) {
        self.store = store
    }

    // MARK: Loading

    func loadSidebar() async {
        do {
            async let serversResult = store.servers()
            async let topicsResult = store.topicSummaries()
            async let unreadResult = store.unreadCount(serverID: nil, topic: nil)
            servers = try await serversResult
            topics = try await topicsResult
            allUnreadCount = try await unreadResult
        } catch {
            recordActionFailure("load the sidebar", error)
        }
    }

    func refreshMessages() async {
        isLoading = true
        searchErrorMessage = nil
        defer { isLoading = false }
        let query = currentQuery(offset: 0)
        do {
            let page = try await store.search(query)
            messages = page
            nextOffset = page.count
            canLoadMore = page.count == Self.pageSize
        } catch {
            messages = []
            canLoadMore = false
            recordSearchFailure("search messages", error)
        }
    }

    /// Called from the list row's `.onAppear`. Loads the next page once the
    /// row nearing the end of what is currently loaded appears, rather than
    /// on every scroll frame or on a fixed timer. A failure here is reported
    /// as an action error, not a search error: the list already shows a
    /// valid (if partial) page, so this must not fall back to the
    /// full-pane "search failed" state that only applies to an empty result.
    func loadMoreIfNeeded(currentItem: MessageSnapshot) async {
        guard canLoadMore, !isLoadingMore else { return }
        guard let index = messages.firstIndex(where: { $0.id == currentItem.id }) else { return }
        let threshold = messages.index(messages.endIndex, offsetBy: -10, limitedBy: messages.startIndex) ?? messages.startIndex
        guard index >= threshold else { return }

        isLoadingMore = true
        defer { isLoadingMore = false }
        let query = currentQuery(offset: nextOffset)
        do {
            let page = try await store.search(query)
            messages.append(contentsOf: page)
            nextOffset += page.count
            canLoadMore = page.count == Self.pageSize
        } catch {
            canLoadMore = false
            recordActionFailure("load more messages", error)
        }
    }

    /// Re-fetches exactly the window of messages already loaded (offset 0,
    /// limit = whatever had been paged in so far), rather than resetting to
    /// the first page the way `refreshMessages` does. Called after a
    /// mutation (`markRead`/`delete`/`markAllRead`) so acting on a message
    /// past page 1 does not scroll the list back to the top or drop that
    /// message out of `messages` — which would otherwise blank
    /// `HistoryDetailView`, since it derives its content by filtering
    /// `messages` against `selection`.
    private func reloadLoadedWindow() async {
        let span = max(nextOffset, Self.pageSize)
        var query = currentQuery(offset: 0)
        query.limit = span
        do {
            let page = try await store.search(query)
            messages = page
            nextOffset = page.count
            canLoadMore = page.count == span
        } catch {
            // Keep the stale `messages` rather than blanking a perfectly
            // good list over an unrelated refresh failure — the mutation
            // itself already succeeded by the time this runs.
            recordActionFailure("refresh messages", error)
        }
    }

    private func currentQuery(offset: Int) -> MessageQuery {
        HistoryQueryBuilder.makeQuery(
            scope: scope, searchText: searchText, priority: priorityFilter,
            tag: tagFilter, dateRange: dateRangeFilter, now: Date(),
            limit: Self.pageSize, offset: offset)
    }

    func dismissActionError() {
        actionErrorMessage = nil
    }

    private func scheduleDebouncedRefresh() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            // `Task.sleep` throws only `CancellationError`, and only when a
            // later keystroke cancels this task via `debounceTask?.cancel()`
            // above — exactly the case this method exists to short-circuit.
            // The `isCancelled` check right after is what actually acts on
            // that, so swallowing the throw here does not hide a failure.
            try? await Task.sleep(for: Self.debounceDelay)
            guard let self, !Task.isCancelled else { return }
            await self.refreshMessages()
        }
    }

    // MARK: Actions

    /// The rows a context action on `snapshot` should apply to: the whole
    /// selection when `snapshot` is part of a multi-row selection, otherwise
    /// just `snapshot` itself. Lets a right-click on an unselected row act
    /// on that row alone without first requiring a click to select it.
    func actionTargets(for snapshot: MessageSnapshot) -> [MessageSnapshot] {
        guard selection.count > 1, selection.contains(snapshot.id) else { return [snapshot] }
        return messages.filter { selection.contains($0.id) }
    }

    func markRead(_ snapshots: [MessageSnapshot], read: Bool) async {
        guard !snapshots.isEmpty else { return }
        do {
            try await store.markRead(snapshots.map(\.id), read: read)
            await reloadLoadedWindow()
            await loadSidebar()
        } catch {
            recordActionFailure(read ? "mark messages read" : "mark messages unread", error)
        }
    }

    func markAllRead(in scope: HistoryScope) async {
        do {
            try await store.markAllRead(serverID: scope.serverID, topic: scope.topic)
            await reloadLoadedWindow()
            await loadSidebar()
        } catch {
            recordActionFailure("mark all messages read", error)
        }
    }

    func delete(_ snapshots: [MessageSnapshot]) async {
        guard !snapshots.isEmpty else { return }
        let ids = Set(snapshots.map(\.id))
        do {
            try await store.deleteMessages(snapshots.map(\.id))
            selection.subtract(ids)
            await reloadLoadedWindow()
            await loadSidebar()
        } catch {
            recordActionFailure("delete messages", error)
        }
    }

    func copy(_ snapshots: [MessageSnapshot]) {
        guard !snapshots.isEmpty else { return }
        let text = snapshots
            .sorted { $0.time < $1.time }
            .map { snapshot in
                [snapshot.title, snapshot.body].compactMap { $0 }.joined(separator: "\n")
            }
            .joined(separator: "\n\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Opens `snapshot.click` in the default browser. `click` is
    /// server-supplied — the same untrusted category `NotificationDecision`
    /// documents for action URLs — so only `http`/`https` are honoured,
    /// never a custom scheme that could hand another app attacker-chosen
    /// input.
    func openClickURL(_ snapshot: MessageSnapshot) {
        guard let click = snapshot.click,
              let url = URL(string: click),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return }
        NSWorkspace.shared.open(url)
    }

    private func recordSearchFailure(_ operation: String, _ error: Error) {
        searchErrorMessage = "Couldn't \(operation). Try again."
        log(operation, error)
    }

    private func recordActionFailure(_ operation: String, _ error: Error) {
        actionErrorMessage = "Couldn't \(operation). Try again."
        log(operation, error)
    }

    /// Fixed, closed vocabulary only — never `error`'s own description. A
    /// `SwiftData`/Cocoa fetch or save error's description can embed a
    /// stored predicate value, which for `search` may be the search text or
    /// tag the user just typed; for `markRead`/`deleteMessages` it can embed
    /// a `uniqueKey`, which traces back to a topic name. `Log.app`'s doc
    /// comment bars all of that, so only the operation name (a literal from
    /// this file, not from the error) and the error's domain/code are
    /// logged — the same shape every other site in this codebase uses.
    private func log(_ operation: String, _ error: Error) {
        let ns = error as NSError
        Log.app.error("history window failed to \(operation, privacy: .public): \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
    }
}
