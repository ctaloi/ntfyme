import Foundation
import SwiftData
import Testing
@testable import NtfyKit

@Test func eventsFromAConnectionBecomeRows() async throws {
    let container = try StoreFixtures.inMemoryContainer()
    let serverID = UUID()
    let context = ModelContext(container)
    let server = Server(id: serverID, name: "Example", baseURLString: "https://ntfy.example.com")
    context.insert(server)
    context.insert(Subscription(topic: "alerts", server: server))
    try context.save()

    let store = MessageStore(modelContainer: container)
    let fake = FakeStreamClient()
    await fake.enqueue([
        .event(try Fixtures.decode(Fixtures.openEvent)),
        .event(try Fixtures.decode(Fixtures.minimalMessage)),
    ])

    let connection = ServerConnection(
        endpoint: NtfyEndpoint(baseURL: URL(string: "https://ntfy.example.com")!,
                               credential: .unauthenticated),
        watermarks: [TopicWatermark(topic: "alerts", lastMessageTime: nil)],
        client: fake, sleeper: ManualSleeper())

    let ingest = Ingest(store: store)
    let pump = await ingest.attach(connection, serverID: serverID)
    defer { pump.cancel() }

    await connection.start()
    #expect(await waitUntil { (try? await store.messageCount()) == 1 })
    await connection.stop()
}

/// Ingest persists the caughtUpTo the connection derived, so a restart
/// resumes from it rather than replaying.
@Test func ingestPersistsTheCaughtUpToTime() async throws {
    let container = try StoreFixtures.inMemoryContainer()
    let serverID = UUID()
    let context = ModelContext(container)
    let server = Server(id: serverID, name: "Example", baseURLString: "https://ntfy.example.com")
    context.insert(server)
    context.insert(Subscription(topic: "alerts", server: server))
    try context.save()

    let store = MessageStore(modelContainer: container)
    let fake = FakeStreamClient()
    await fake.enqueue([.event(try Fixtures.decode(Fixtures.minimalMessage))])

    let connection = ServerConnection(
        endpoint: NtfyEndpoint(baseURL: URL(string: "https://ntfy.example.com")!,
                               credential: .unauthenticated),
        watermarks: [TopicWatermark(topic: "alerts", lastMessageTime: nil)],
        client: fake, sleeper: ManualSleeper())

    let ingest = Ingest(store: store)
    let pump = await ingest.attach(connection, serverID: serverID)
    defer { pump.cancel() }

    await connection.start()
    #expect(await waitUntil { ((try? await store.caughtUpTo(forServer: serverID)) ?? nil) != nil })
    // Not just `!= nil`: that would pass for `Date.distantPast`. The
    // persisted value must be the exact server time the connection derived,
    // matching `Fixtures.minimalMessage`'s `time` field.
    let persisted = try #require(try await store.caughtUpTo(forServer: serverID))
    let connectionCaughtUpTo = try #require(await connection.caughtUpTo)
    #expect(persisted == connectionCaughtUpTo)
    #expect(persisted == Date(timeIntervalSince1970: 1_788_353_322))
    await connection.stop()
}

/// A reconnect replay can hand the collector thousands of events well before
/// any tick would fire; the count ceiling, not the ticker, must be what
/// flushes them.
@Test func batchCeilingFlushesIndependentlyOfTheTicker() async throws {
    let container = try StoreFixtures.inMemoryContainer()
    let serverID = UUID()
    let context = ModelContext(container)
    let server = Server(id: serverID, name: "Example", baseURLString: "https://ntfy.example.com")
    context.insert(server)
    context.insert(Subscription(topic: "alerts", server: server))
    try context.save()

    let store = MessageStore(modelContainer: container)
    let fake = FakeStreamClient()
    // Distinct ids so none is treated as a duplicate of another.
    let events: [NtfyStreamClient.StreamElement] = (0..<600).map { index in
        .event(NtfyEvent(
            id: "batch-\(index)", time: 1_788_400_000 + index, expires: nil,
            event: "message", topic: "alerts", title: nil, message: "m",
            priority: nil, tags: nil, click: nil, icon: nil, contentType: nil,
            actions: nil, attachment: nil))
    }
    await fake.enqueue(events)

    let connection = ServerConnection(
        endpoint: NtfyEndpoint(baseURL: URL(string: "https://ntfy.example.com")!,
                               credential: .unauthenticated),
        watermarks: [TopicWatermark(topic: "alerts", lastMessageTime: nil)],
        client: fake, sleeper: ManualSleeper())

    // A window the test's own bound can't reach: only the count ceiling, not
    // a tick, can be what flushes 600 events before waitUntil gives up.
    let ingest = Ingest(store: store, batchWindow: .seconds(60))
    let pump = await ingest.attach(connection, serverID: serverID)
    defer { pump.cancel() }

    await connection.start()
    #expect(await waitUntil { ((try? await store.messageCount()) ?? 0) >= 500 })
    await connection.stop()
}

/// `attach`'s returned task is documented as running "until it is cancelled".
/// Its trailing flush is what makes that promise durable: without it, a
/// batch collected but not yet ticked out would be lost the moment the
/// caller cancels.
@Test func cancellationTriggersAFinalFlush() async throws {
    let container = try StoreFixtures.inMemoryContainer()
    let serverID = UUID()
    let context = ModelContext(container)
    let server = Server(id: serverID, name: "Example", baseURLString: "https://ntfy.example.com")
    context.insert(server)
    context.insert(Subscription(topic: "alerts", server: server))
    try context.save()

    let store = MessageStore(modelContainer: container)
    let fake = FakeStreamClient()
    await fake.enqueue([.event(try Fixtures.decode(Fixtures.minimalMessage))])

    let connection = ServerConnection(
        endpoint: NtfyEndpoint(baseURL: URL(string: "https://ntfy.example.com")!,
                               credential: .unauthenticated),
        watermarks: [TopicWatermark(topic: "alerts", lastMessageTime: nil)],
        client: fake, sleeper: ManualSleeper())

    // A window the test's own bound can't reach, so only the trailing
    // post-cancellation flush -- not a tick -- can be what writes this one
    // event.
    let ingest = Ingest(store: store, batchWindow: .seconds(60))
    let pump = await ingest.attach(connection, serverID: serverID)

    await connection.start()
    // Wait for the connection to have actually processed the line (the same
    // synchronization `ingestPersistsTheCaughtUpToTime` uses) before
    // cancelling, so this test exercises "did the final flush run", not "did
    // the event happen to arrive before we cancelled".
    #expect(await waitUntil { await connection.caughtUpTo != nil })
    pump.cancel()
    #expect(await waitUntil { (try? await store.messageCount()) == 1 })
    // Distinguishes "the final flush wrote this row" from "some other path
    // did": insertedCount only advances inside `flush`, and the ticker
    // (batchWindow: 60s) cannot have run by now.
    #expect(await ingest.insertedCount == 1)
    await connection.stop()
}
