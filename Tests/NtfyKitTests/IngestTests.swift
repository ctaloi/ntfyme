import Foundation
import SwiftData
import Testing
@testable import NtfyKit

private func bufferEvent(_ id: String, time: Int = 100) -> NtfyEvent {
    let json = """
    {"id":"\(id)","time":\(time),"event":"message","topic":"alerts","message":"m"}
    """
    return try! JSONDecoder().decode(NtfyEvent.self, from: Data(json.utf8))
}

private func makeServer() throws -> (ModelContainer, MessageStore, UUID) {
    let container = try StoreFixtures.inMemoryContainer()
    let serverID = UUID()
    let context = ModelContext(container)
    let server = Server(id: serverID, name: "Example", baseURLString: "https://ntfy.example.com")
    context.insert(server)
    context.insert(Subscription(topic: "alerts", server: server))
    try context.save()
    return (container, MessageStore(modelContainer: container), serverID)
}

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
    // A message and then the keepalive that proves the server has delivered
    // everything up to its time. The keepalive is what moves the resume point
    // (§5.2); the message alone must not, so a script without one would pin
    // nothing here.
    await fake.enqueue([
        .event(try Fixtures.decode(Fixtures.minimalMessage)),
        .event(try Fixtures.decode(Fixtures.laterKeepaliveEvent)),
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
    #expect(await waitUntil { ((try? await store.caughtUpTo(forServer: serverID)) ?? nil) != nil })
    // Not just `!= nil`: that would pass for `Date.distantPast`. The persisted
    // value must be the exact server time of the keepalive — and specifically
    // not `minimalMessage`'s 1_788_353_322, which a rule that advanced on any
    // line would have produced.
    let persisted = try #require(try await store.caughtUpTo(forServer: serverID))
    let connectionCaughtUpTo = try #require(await connection.caughtUpTo)
    #expect(persisted == connectionCaughtUpTo)
    #expect(persisted == Date(timeIntervalSince1970: 1_788_353_400))
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
    // Wait for the connection to have actually processed the line before
    // cancelling, so this test exercises "did the final flush run", not "did
    // the event happen to arrive before we cancelled". The watermark, not
    // `caughtUpTo`: this script is a lone message, and §5.2 moves `caughtUpTo`
    // only on a keepalive, so it would stay nil here forever. `record(_:)`
    // writes the watermark in the same actor step that yields the event, so
    // it is the same synchronization point the old `caughtUpTo` read was.
    #expect(await waitUntil { await connection.watermarkSnapshot().first?.lastMessageTime != nil })
    pump.cancel()
    #expect(await waitUntil { (try? await store.messageCount()) == 1 })
    // Distinguishes "the final flush wrote this row" from "some other path
    // did": insertedCount only advances inside `flush`, and the ticker
    // (batchWindow: 60s) cannot have run by now.
    #expect(await ingest.insertedCount == 1)
    await connection.stop()
}

/// The persisted resume point must come from the batch that was just written,
/// not from a cross-actor read of `ServerConnection.caughtUpTo`. The
/// connection's value is a different, unordered channel: by the time a flush
/// reads it, it can already have advanced past events still sitting in this
/// actor's buffer or in the stream's, and persisting it then dying puts those
/// events below `since` on the next launch.
///
/// The gap between the two answers is made explicit rather than raced for: the
/// connection is seeded with a resume point far ahead of anything in the
/// script, so a flush that reads the connection persists 1_788_400_000 while a
/// flush that reads its own batch persists the keepalive's 1_788_353_400. (The
/// seed is ahead of the stream only to separate the two rules in one run; in
/// service it comes from the store, which is behind by construction.)
@Test func theResumePointComesFromTheBatchNotTheConnection() async throws {
    let (_, store, serverID) = try makeServer()
    let fake = FakeStreamClient()
    await fake.enqueue([
        .event(try Fixtures.decode(Fixtures.minimalMessage)),
        .event(try Fixtures.decode(Fixtures.laterKeepaliveEvent)),
    ])

    let connection = ServerConnection(
        endpoint: NtfyEndpoint(baseURL: URL(string: "https://ntfy.example.com")!,
                               credential: .unauthenticated),
        watermarks: [TopicWatermark(topic: "alerts", lastMessageTime: nil)],
        caughtUpTo: Date(timeIntervalSince1970: 1_788_400_000),
        client: fake, sleeper: ManualSleeper())

    let ingest = Ingest(store: store)
    let pump = await ingest.attach(connection, serverID: serverID)
    defer { pump.cancel() }

    await connection.start()
    #expect(await waitUntil { ((try? await store.caughtUpTo(forServer: serverID)) ?? nil) != nil })
    let persisted = try #require(try await store.caughtUpTo(forServer: serverID))
    #expect(persisted == Date(timeIntervalSince1970: 1_788_353_400))
    // And the connection really did hold the larger value throughout, so the
    // assertion above is a choice between two live answers, not a comparison
    // against something that was never there.
    #expect(await connection.caughtUpTo == Date(timeIntervalSince1970: 1_788_400_000))
    await connection.stop()
}

/// A batch with no keepalive in it proved nothing, however many messages it
/// carried, and must persist nothing — even when the connection is holding a
/// resume point from a previous life. This is the shape a restart has: the
/// store hands the connection its last known point, and the first messages to
/// arrive are replay, which under ntfy's per-topic replay order says nothing
/// about how far the other topics have been delivered.
@Test func aBatchWithNoKeepaliveDoesNotAdvanceTheResumePoint() async throws {
    let (_, store, serverID) = try makeServer()
    let fake = FakeStreamClient()
    await fake.enqueue([
        .event(try Fixtures.decode(Fixtures.openEvent)),
        .event(try Fixtures.decode(Fixtures.minimalMessage)),
    ])

    let connection = ServerConnection(
        endpoint: NtfyEndpoint(baseURL: URL(string: "https://ntfy.example.com")!,
                               credential: .unauthenticated),
        watermarks: [TopicWatermark(topic: "alerts", lastMessageTime: nil)],
        caughtUpTo: Date(timeIntervalSince1970: 1_788_400_000),
        client: fake, sleeper: ManualSleeper())

    let ingest = Ingest(store: store)
    let pump = await ingest.attach(connection, serverID: serverID)
    defer { pump.cancel() }

    await connection.start()
    // The row landing is the proof a flush ran to completion. Asserting the
    // resume point stayed nil before that would pass by simply being early.
    #expect(await waitUntil { (try? await store.messageCount()) == 1 })
    #expect(try await store.caughtUpTo(forServer: serverID) == nil)
    await connection.stop()
}

/// A batch whose insert failed goes back on the FRONT of the buffer. The
/// collector keeps appending throughout the failed insert, and stream order is
/// the entire basis for "this keepalive proves everything before it was
/// delivered" — an append would put the retry batch after events that follow
/// it on the wire and make the next batch's mark a lie.
@Test func aFailedBatchGoesBackOnTheFrontOfTheBuffer() async {
    let buffer = Ingest.Buffer()
    _ = await buffer.append(bufferEvent("arrived-during-the-failed-insert"))
    await buffer.restore([bufferEvent("older-1"), bufferEvent("older-2")])
    let drained = await buffer.drain()
    #expect(drained.map(\.id) == ["older-1", "older-2", "arrived-during-the-failed-insert"])
}

/// The retry buffer is bounded, and the bound drops the *newest* arrivals —
/// never the batch waiting to be written. Dropping anything at all means this
/// buffer no longer holds every event the stream delivered, so the resume
/// point freezes: no later keepalive can honestly claim everything before it
/// was stored. That costs a replay on the next launch; advancing instead would
/// cost the messages themselves.
@Test func aFullBufferDropsTheNewestAndFreezesTheResumePoint() async {
    let buffer = Ingest.Buffer()
    for index in 0..<Ingest.Buffer.capacity {
        _ = await buffer.append(bufferEvent("held-\(index)"))
    }
    #expect(await buffer.shouldPersist(Date(timeIntervalSince1970: 1_000)) == true)

    let count = await buffer.append(bufferEvent("overflow"))
    #expect(count == Ingest.Buffer.capacity)
    #expect(await buffer.shouldPersist(Date(timeIntervalSince1970: 2_000)) == false)

    let drained = await buffer.drain()
    #expect(drained.count == Ingest.Buffer.capacity)
    #expect(drained.first?.id == "held-0")
    #expect(drained.contains { $0.id == "overflow" } == false)
}

/// `shouldPersist` is the ticker's cheap filter: it exists so an idle
/// connection does not re-fetch and re-write a `Server` row four times a
/// second for the life of the app.
@Test func aMarkThatIsNotNewerThanThePersistedOneIsSkipped() async {
    let buffer = Ingest.Buffer()
    let mark = Date(timeIntervalSince1970: 1_788_353_400)
    #expect(await buffer.shouldPersist(mark) == true)
    await buffer.markPersisted(mark)
    #expect(await buffer.shouldPersist(mark) == false)
    #expect(await buffer.shouldPersist(mark.addingTimeInterval(-1)) == false)
    #expect(await buffer.shouldPersist(mark.addingTimeInterval(1)) == true)
}
