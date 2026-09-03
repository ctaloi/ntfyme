import Foundation
import SwiftData
import Testing
import NtfyKit
@testable import NtfyMe

/// Plain logic tests — no AppKit rendering, so no `requiresSnapshotRendering`
/// needed here, unlike `HistorySnapshotTests.swift`.

@MainActor
private func makeStore(messageIsRead: Bool) throws -> (store: MessageStore, messageID: String) {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: Server.self, Subscription.self, Message.self, Attachment.self,
                                       configurations: config)
    let context = ModelContext(container)
    let server = Server(name: "Home Lab", baseURLString: "https://ntfy.homelab.example", sortOrder: 0)
    context.insert(server)
    context.insert(Subscription(topic: "alerts", server: server))
    let message = Message(serverID: server.id, topic: "alerts", messageID: "m1", time: Date(),
                          title: "Disk space critical", body: "`/var` is at 96%.", isRead: messageIsRead)
    context.insert(message)
    try context.save()
    return (MessageStore(modelContainer: container), message.uniqueKey)
}

/// The bug report: "when reading in message view item is not marked as read
/// when clicking on it." `HistoryListView`'s selection `onChange` calls
/// `markSelectedRead()` after a click lands in `selection` — this exercises
/// that method directly (Mail-style: viewing marks read, immediately, no
/// dwell) without needing the AppKit rendering path at all.
@MainActor
@Test func selectingAnUnreadMessageMarksItRead() async throws {
    let (store, messageID) = try makeStore(messageIsRead: false)
    let viewModel = HistoryViewModel(store: store)
    await viewModel.loadSidebar()
    await viewModel.refreshMessages()
    #expect(viewModel.messages.first?.isRead == false)

    viewModel.selection = [messageID]
    await viewModel.markSelectedRead()

    #expect(viewModel.messages.first(where: { $0.id == messageID })?.isRead == true)
    // Not just local state — the store itself, so a relaunch or the sidebar
    // badge sees the same thing.
    let stored = try await store.message(uniqueKey: messageID)
    #expect(stored?.isRead == true)
}

@MainActor
@Test func selectingAnAlreadyReadMessageIsANoOp() async throws {
    let (store, messageID) = try makeStore(messageIsRead: true)
    let viewModel = HistoryViewModel(store: store)
    await viewModel.loadSidebar()
    await viewModel.refreshMessages()

    viewModel.selection = [messageID]
    // Would be harmless either way, but exercising it against an
    // already-read message is what confirms the `!snapshot.isRead` guard
    // in `markSelectedRead()` is actually load-bearing, not just untested.
    await viewModel.markSelectedRead()

    #expect(viewModel.messages.first(where: { $0.id == messageID })?.isRead == true)
}

@MainActor
@Test func multiSelectionDoesNotMarkAnythingRead() async throws {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: Server.self, Subscription.self, Message.self, Attachment.self,
                                       configurations: config)
    let context = ModelContext(container)
    let server = Server(name: "Home Lab", baseURLString: "https://ntfy.homelab.example", sortOrder: 0)
    context.insert(server)
    context.insert(Subscription(topic: "alerts", server: server))
    let a = Message(serverID: server.id, topic: "alerts", messageID: "a", time: Date(),
                    title: "A", body: "A", isRead: false)
    let b = Message(serverID: server.id, topic: "alerts", messageID: "b", time: Date().addingTimeInterval(-1),
                    title: "B", body: "B", isRead: false)
    context.insert(a)
    context.insert(b)
    try context.save()

    let store = MessageStore(modelContainer: container)
    let viewModel = HistoryViewModel(store: store)
    await viewModel.loadSidebar()
    await viewModel.refreshMessages()

    // A right-click multi-selection (or shift-click) is not "viewing" one
    // message the way a single click is — Mail does not bulk-mark-read on
    // a multi-selection either, and neither should this.
    viewModel.selection = [a.uniqueKey, b.uniqueKey]
    await viewModel.markSelectedRead()

    #expect(viewModel.messages.allSatisfy { !$0.isRead })
}

/// `HistoryScope.unread` and the Filter menu's own `unreadOnly` toggle are
/// two independent ways to reach the same `MessageQuery.unreadOnly`, and
/// `HistoryQueryBuilder.makeQuery` is what ORs them together — pure, no
/// store, so worth pinning directly the same way `DateRangeFilter.bounds`
/// already is.
@Test func unreadScopeImpliesUnreadOnlyEvenWhenTheToggleIsOff() {
    let query = HistoryQueryBuilder.makeQuery(
        scope: .unread, searchText: "", priority: .any, tag: "", dateRange: .any,
        unreadOnly: false, now: Date(), limit: 10, offset: 0)
    #expect(query.unreadOnly)
}

@Test func theUnreadOnlyToggleAppliesWithinAnyScope() {
    let query = HistoryQueryBuilder.makeQuery(
        scope: .topic(serverID: UUID(), topic: "alerts"), searchText: "", priority: .any, tag: "",
        dateRange: .any, unreadOnly: true, now: Date(), limit: 10, offset: 0)
    #expect(query.unreadOnly)
}

@Test func neitherUnreadSignalMeansUnreadOnlyIsFalse() {
    let query = HistoryQueryBuilder.makeQuery(
        scope: .all, searchText: "", priority: .any, tag: "", dateRange: .any,
        unreadOnly: false, now: Date(), limit: 10, offset: 0)
    #expect(!query.unreadOnly)
}

// MARK: - Cross-surface refresh

/// The receiving end of the mute bug. `SettingsModelTests` pins that
/// `onTopicSettingsChanged` fires after a successful write; this pins what
/// the hook is *for* — a sidebar that has already loaded shows the new state
/// afterwards instead of the state it read before the write, which is the
/// stale bell-slash the user reported.
///
/// The closure is the same one line `AppDelegate` hands to
/// `AppGraph.makeSettingsModel(onTopicSettingsChanged:)`, standing in for
/// its `HistoryWindowController.refreshSidebar()`: that controller keeps its
/// view model private, so asserting through it would mean opening an
/// `NSWindow` this test has no use for.
@MainActor
@Test func aMuteWrittenInSettingsReachesAnAlreadyLoadedSidebar() async throws {
    let (store, _) = try makeStore(messageIsRead: false)
    let viewModel = HistoryViewModel(store: store)
    await viewModel.loadSidebar()
    #expect(viewModel.topics.count == 1)
    #expect(viewModel.topics.first?.muted == false)

    // Unique per run for both, so a leftover suite or Keychain item from an
    // earlier run cannot decide this test — matching `SettingsModelTests`.
    let suite = "dev.aloi.NtfyMe.historyViewModelTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let settings = SettingsModel(
        store: store, preferences: PreferencesStore(defaults: defaults),
        keychain: KeychainStore(service: suite), defaults: defaults,
        onTopicSettingsChanged: { await viewModel.loadSidebar() })

    let serverID = try #require(viewModel.servers.first?.id)
    await settings.setAlertSettings(TopicAlertSettings(muted: true, minAlertPriority: 1),
                                    serverID: serverID, topic: "alerts")

    // Nothing in this test reloaded the sidebar — the hook did.
    #expect(viewModel.topics.first?.muted == true)
}
