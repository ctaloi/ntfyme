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
    /// Where `AttachmentDownloader` writes files, for resolving a Quick Look
    /// preview from `MessageSnapshot.attachment?.localFilename`. `nil` until
    /// a wiring pass sets it (`HistoryWindowController.init`) — that must be
    /// the exact same directory `RetentionScheduler.attachmentsDirectory()`
    /// uses, or a preview would either fail to resolve or, worse, resolve
    /// against the wrong directory.
    let attachmentsDirectory: URL?

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
    /// Independent of `scope == .unread` (the sidebar's "Unread" smart
    /// view) — this is the Filter menu's own toggle, usable within any
    /// scope (e.g. "unread messages in #alerts"). `currentQuery` ORs the
    /// two rather than picking one, so either one alone is enough to filter.
    var unreadOnly: Bool = false {
        didSet {
            guard oldValue != unreadOnly else { return }
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
    /// Set whenever the current page comes back empty, to tell apart the
    /// two reasons `messages` can be empty: nothing has ever arrived, or
    /// the scope/filters exclude everything that has. `HistoryListView`'s
    /// empty state reads this to choose the right words — an unconditional
    /// "nothing matches the current filters" told a brand-new user with no
    /// filters set that their (nonexistent) filters were hiding messages,
    /// which sent them hunting for a control that was never the problem.
    private(set) var archiveIsEmpty = false
    private var nextOffset = 0
    private var debounceTask: Task<Void, Never>?

    /// Whether anything narrower than "no constraint at all" is active —
    /// used the same place `archiveIsEmpty` is (to tell a genuinely empty
    /// archive from a filtered-to-nothing one) and to gate the "Clear
    /// Filters" action to when there is actually something to clear.
    var hasActiveFilters: Bool {
        scope != .all || !searchText.isEmpty || !tagFilter.isEmpty
            || priorityFilter != .any || dateRangeFilter != .any || unreadOnly
    }

    /// Clears every filter `reveal(messageKey:)` already clears for the
    /// same reason — a message, or in this case an entire archive, hidden
    /// by an active filter reads as broken rather than merely filtered —
    /// exposed here so the filtered-empty state's "Clear Filters" button
    /// isn't the only way that behavior is reachable.
    func clearFilters() {
        scope = .all
        searchText = ""
        tagFilter = ""
        priorityFilter = .any
        dateRangeFilter = .any
        unreadOnly = false
    }

    init(store: MessageStore, attachmentsDirectory: URL? = nil) {
        self.store = store
        self.attachmentsDirectory = attachmentsDirectory
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
            archiveIsEmpty = page.isEmpty ? await isArchiveEmpty() : false
        } catch {
            messages = []
            canLoadMore = false
            recordSearchFailure("search messages", error)
        }
    }

    /// Only called when the current page is already empty, so this is never
    /// on the hot path a keystroke drives. A failure here is not worth
    /// failing the whole refresh over — the search above already succeeded,
    /// `messages` is trustworthy — so it falls back to the more common
    /// wording (filtered-empty) rather than guessing wrong in the rarer
    /// direction (claiming a non-empty archive is empty).
    private func isArchiveEmpty() async -> Bool {
        do {
            return try await store.messageCount() == 0
        } catch {
            log("check whether the archive is empty", error)
            return false
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
            archiveIsEmpty = page.isEmpty ? await isArchiveEmpty() : false
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
            tag: tagFilter, dateRange: dateRangeFilter, unreadOnly: unreadOnly, now: Date(),
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

    /// `serverID`/`topic` taken directly rather than a `HistoryScope`: the
    /// sidebar's per-server "Mark All Read" needs a server-wide scope that
    /// is no longer a selectable `HistoryScope` case (servers are a plain
    /// section header now, not their own destination), and `store
    /// .markAllRead` already takes exactly these two optionals.
    func markAllRead(serverID: UUID?, topic: String?) async {
        do {
            try await store.markAllRead(serverID: serverID, topic: topic)
            await reloadLoadedWindow()
            await loadSidebar()
        } catch {
            recordActionFailure("mark all messages read", error)
        }
    }

    /// Mail-style "viewing marks read": called from the list's selection
    /// change (`HistoryListView`'s `.onChange(of: viewModel.selection)`),
    /// not from `selection`'s own setter — a plain, directly awaitable
    /// method is unit-testable on its own, where a fire-and-forget `Task`
    /// spawned inside a property observer is not. Selecting a message the
    /// user is not actually viewing (a multi-selection) must not mark
    /// anything; only a single, genuinely-displayed selection does.
    func markSelectedRead() async {
        guard selection.count == 1, let id = selection.first,
              let snapshot = messages.first(where: { $0.id == id }), !snapshot.isRead
        else { return }
        await markRead([snapshot], read: true)
    }

    func delete(_ snapshots: [MessageSnapshot]) async {
        guard !snapshots.isEmpty else { return }
        let ids = Set(snapshots.map(\.id))
        do {
            try await store.deleteMessages(snapshots.map(\.id), attachmentsDirectory: attachmentsDirectory)
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
    /// server-supplied — spec §9: a message is attacker-controlled — so this
    /// goes through `NtfyURLPolicy`, the one place that rule is expressed,
    /// rather than a second local scheme check.
    func openClickURL(_ snapshot: MessageSnapshot) {
        guard let url = NtfyURLPolicy.sanitized(snapshot.click) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Wide enough to cover retention's default per-topic cap
    /// (`RetentionPolicy.default.maxMessagesPerTopic`) without importing a
    /// hard dependency on that value — a widened `reveal` fetch bounded by
    /// `since:` a specific message's own time is already capped by whatever
    /// retention the user has configured; this only bounds the pathological
    /// case of a much larger configured limit.
    private static let revealFetchLimit = 20_000

    /// Reveals one message by its store key: widens the scope and clears
    /// every filter that could otherwise make a real message invisible,
    /// loads it if it is not already in the current page, and selects it —
    /// called for "open this message" from the menu bar popover and from a
    /// notification click (spec §6), both of which hand this the same
    /// `MessageSnapshot.id`.
    ///
    /// Clearing filters rather than merely widening `scope` is the point of
    /// this method existing instead of a caller setting `scope`/`selection`
    /// directly: a user with an active topic, priority, tag, search, or date
    /// filter would otherwise "select" a message that the current filters
    /// hide, which reads as the feature being broken, not as a message that
    /// is merely filtered out of view right now.
    ///
    /// If the key no longer resolves — retention (spec §8) pruned it between
    /// whoever captured the key and this call landing — there is no message
    /// left to select, but `Message.topicScope(forUniqueKey:)` can still
    /// recover which server and topic it belonged to from the key's own
    /// structure. Scoping the window there, with a banner explaining why
    /// nothing is selected, is more useful than either doing nothing or
    /// silently landing on the topic with no explanation for the missing
    /// click.
    func reveal(messageKey: String) async {
        do {
            guard let snapshot = try await store.message(uniqueKey: messageKey) else {
                if let target = Message.topicScope(forUniqueKey: messageKey) {
                    searchText = ""
                    tagFilter = ""
                    priorityFilter = .any
                    dateRangeFilter = .any
                    scope = .topic(serverID: target.serverID, topic: target.topic)
                    await refreshMessages()
                }
                // Not `recordActionFailure`'s usual shape ("Couldn't X. Try
                // again.") — retrying resolves nothing once a message is
                // pruned, so the banner says what actually happened instead.
                actionErrorMessage = "That message is no longer in the archive."
                return
            }

            searchText = ""
            tagFilter = ""
            priorityFilter = .any
            dateRangeFilter = .any
            scope = .topic(serverID: snapshot.serverID, topic: snapshot.topic)
            await refreshMessages()

            if !messages.contains(where: { $0.id == snapshot.id }) {
                // Not on the first page. Widen just enough to include it —
                // `since: snapshot.time` bounds this to the target and
                // everything newer in its topic, not an unbounded fetch —
                // rather than assume it is nearby and silently show the
                // wrong selection.
                var query = currentQuery(offset: 0)
                query.since = snapshot.time
                query.limit = Self.revealFetchLimit
                do {
                    let widened = try await store.search(query)
                    messages = widened
                    nextOffset = widened.count
                    canLoadMore = widened.count == Self.revealFetchLimit
                } catch {
                    recordActionFailure("open that message", error)
                    return
                }
            }

            selection = [snapshot.id]
        } catch {
            recordActionFailure("open that message", error)
        }
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
