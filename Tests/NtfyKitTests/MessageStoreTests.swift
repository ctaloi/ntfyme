import Foundation
import SwiftData
import Testing
@testable import NtfyKit

private func event(_ id: String, topic: String = "alerts", time: Int, body: String) -> NtfyEvent {
    let json = """
    {"id":"\(id)","time":\(time),"event":"message","topic":"\(topic)","message":"\(body)"}
    """
    return try! JSONDecoder().decode(NtfyEvent.self, from: Data(json.utf8))
}

private func makeStore() throws -> (MessageStore, UUID) {
    let container = try StoreFixtures.inMemoryContainer()
    let serverID = UUID()
    let context = ModelContext(container)
    let server = Server(id: serverID, name: "Example",
                        baseURLString: "https://ntfy.example.com")
    context.insert(server)
    context.insert(Subscription(topic: "alerts", server: server))
    try context.save()
    return (MessageStore(modelContainer: container), serverID)
}

@Test func insertingMessagesPersistsThem() async throws {
    let (store, serverID) = try makeStore()
    let result = try await store.insert(
        [event("a", time: 100, body: "one"), event("b", time: 200, body: "two")],
        serverID: serverID)
    #expect(result.inserted == 2)
    #expect(result.duplicatesSkipped == 0)
    #expect(try await store.messageCount() == 2)
}

/// The invariant the whole reconnect design rests on: an overlapping replay
/// window must upsert, not duplicate.
@Test func replayingAnOverlappingWindowDoesNotDuplicateRows() async throws {
    let (store, serverID) = try makeStore()
    _ = try await store.insert([event("a", time: 100, body: "one"),
                                event("b", time: 200, body: "two")], serverID: serverID)
    let second = try await store.insert([event("b", time: 200, body: "two"),
                                         event("c", time: 300, body: "three")], serverID: serverID)
    #expect(second.inserted == 1)
    #expect(second.duplicatesSkipped == 1)
    #expect(try await store.messageCount() == 3)
}

/// Same message id on two different topics is two different messages.
///
/// Subscribes to both topics, not just `alerts` — the store's contract is
/// that a `Subscription` row exists before messages for a topic arrive
/// (`advanceWatermarks` logs an error otherwise); this test's job is to
/// prove the dedupe key, not to exercise that error path incidentally.
@Test func theSameMessageIdOnDifferentTopicsIsNotADuplicate() async throws {
    let container = try StoreFixtures.inMemoryContainer()
    let serverID = UUID()
    let context = ModelContext(container)
    let server = Server(id: serverID, name: "Example",
                        baseURLString: "https://ntfy.example.com")
    context.insert(server)
    context.insert(Subscription(topic: "alerts", server: server))
    context.insert(Subscription(topic: "deploys", server: server))
    try context.save()
    let store = MessageStore(modelContainer: container)

    let result = try await store.insert(
        [event("same", topic: "alerts", time: 100, body: "a"),
         event("same", topic: "deploys", time: 100, body: "b")], serverID: serverID)
    #expect(result.inserted == 2)
    #expect(try await store.messageCount() == 2)
}

@Test func insertingAdvancesTheTopicWatermark() async throws {
    let (store, serverID) = try makeStore()
    _ = try await store.insert([event("a", time: 100, body: "one"),
                                event("b", time: 300, body: "two"),
                                event("c", time: 200, body: "three")], serverID: serverID)
    let marks = try await store.watermarks(forServer: serverID)
    #expect(marks.count == 1)
    #expect(marks.first?.topic == "alerts")
    // Newest wins regardless of arrival order.
    #expect(marks.first?.lastMessageTime == Date(timeIntervalSince1970: 300))
}

/// An out-of-order late arrival must not move the watermark backwards.
@Test func anOlderMessageDoesNotRewindTheWatermark() async throws {
    let (store, serverID) = try makeStore()
    _ = try await store.insert([event("b", time: 300, body: "new")], serverID: serverID)
    _ = try await store.insert([event("a", time: 100, body: "old")], serverID: serverID)
    let marks = try await store.watermarks(forServer: serverID)
    #expect(marks.first?.lastMessageTime == Date(timeIntervalSince1970: 300))
}

@Test func caughtUpToRoundTrips() async throws {
    let (store, serverID) = try makeStore()
    #expect(try await store.caughtUpTo(forServer: serverID) == nil)
    let t = Date(timeIntervalSince1970: 1_788_353_322)
    try await store.setCaughtUpTo(t, forServer: serverID)
    #expect(try await store.caughtUpTo(forServer: serverID) == t)
}

@Test func messagesComeBackNewestFirst() async throws {
    let (store, serverID) = try makeStore()
    _ = try await store.insert([event("a", time: 100, body: "old"),
                                event("c", time: 300, body: "new"),
                                event("b", time: 200, body: "mid")], serverID: serverID)
    let page = try await store.messages(forServer: serverID, topic: nil, limit: 10)
    #expect(page.map(\.body) == ["new", "mid", "old"])
}

/// Non-message events carry no content and must not become rows.
@Test func keepaliveAndOpenEventsAreNotStored() async throws {
    let (store, serverID) = try makeStore()
    let open = try Fixtures.decode(Fixtures.openEvent)
    let keepalive = try Fixtures.decode(Fixtures.keepaliveEvent)
    let result = try await store.insert([open, keepalive], serverID: serverID)
    #expect(result.inserted == 0)
    #expect(try await store.messageCount() == 0)
}

/// This is the entire reason the skip exists (not the brief's 8 tests —
/// added here because none of them exercise it): `Message.isRead` is local
/// state the server knows nothing about, and every reconnect deliberately
/// re-requests an overlapping window. If a replay ever overwrote the stored
/// row, marking a message read would be undone on the next reconnect.
@Test func replayingDoesNotResetIsReadToFalse() async throws {
    let container = try StoreFixtures.inMemoryContainer()
    let serverID = UUID()
    let context = ModelContext(container)
    let server = Server(id: serverID, name: "Example",
                        baseURLString: "https://ntfy.example.com")
    context.insert(server)
    context.insert(Subscription(topic: "alerts", server: server))
    try context.save()
    let store = MessageStore(modelContainer: container)

    _ = try await store.insert([event("a", time: 100, body: "one")], serverID: serverID)

    // Mark it read directly against the same container, the way a future
    // mark-read API would.
    let stored = try context.fetch(FetchDescriptor<Message>()).first
    #expect(stored != nil)
    stored?.isRead = true
    try context.save()

    // Reconnect replays the same window.
    _ = try await store.insert([event("a", time: 100, body: "one")], serverID: serverID)

    let page = try await store.messages(forServer: serverID, topic: nil, limit: 10)
    #expect(page.first?.isRead == true)
}
