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

/// A single server's `Ingest` is not necessarily paired 1:1 with one
/// connection's `pump()` -- nothing about `attach` prevents a second call for
/// the same `Ingest` instance, and `ConnectionCoordinator` shares one `Ingest`
/// across every server it attaches, so two connections' pumps CAN share one
/// `Ingest` even for what is, from the store's point of view, a single
/// server. That matters because two independent `pump()` invocations have no
/// structural relationship to each other, unlike one pump's own collector,
/// ticker, and trailing calls: `withTaskGroup` already serializes those
/// against each other (the group does not return until every child task,
/// including one suspended mid-`store.insert`, has fully finished, so a lone
/// pump's own trailing flush can never observe a sibling call still in
/// flight). Two separate pumps have no such guarantee, so their trailing
/// flushes can genuinely race on the shared actor's serialization state.
/// Before the fix, whichever one lost that race skipped instead of draining,
/// and permanently dropped whatever its own buffer held.
@Test func twoPumpsSharingOneIngestBothDrainOnCancellation() async throws {
    let (_, store, serverID) = try makeServer()

    // 3033, not 3000: the collector flushes on every 500-event ceiling, so a
    // round multiple would let the ceiling drain everything on its own,
    // leaving nothing for the trailing flush to prove. The 33-event
    // remainder past the last ceiling can ONLY ever be drained by a trailing
    // flush -- never a ceiling crossing -- so it is a *guaranteed*, not
    // merely likely, tail still sitting in each buffer at cancellation time.
    let total = 3033
    let fakeA = FakeStreamClient()
    let fakeB = FakeStreamClient()
    await fakeA.enqueueThenHang((0..<total).map { .event(bufferEvent("pump-a-\($0)", time: 1_788_800_000 + $0)) })
    await fakeB.enqueueThenHang((0..<total).map { .event(bufferEvent("pump-b-\($0)", time: 1_788_900_000 + $0)) })

    let connectionA = ServerConnection(
        endpoint: NtfyEndpoint(baseURL: URL(string: "https://ntfy.example.com")!,
                               credential: .unauthenticated),
        watermarks: [TopicWatermark(topic: "alerts", lastMessageTime: nil)],
        client: fakeA, sleeper: ManualSleeper())
    let connectionB = ServerConnection(
        endpoint: NtfyEndpoint(baseURL: URL(string: "https://ntfy.example.com")!,
                               credential: .unauthenticated),
        watermarks: [TopicWatermark(topic: "alerts", lastMessageTime: nil)],
        client: fakeB, sleeper: ManualSleeper())

    // A window this test's own bound can't reach: with the ticker parked,
    // only ceiling crossings and the eventual trailing flush move any data,
    // so the 33-event remainder is untouched by anything but the race this
    // test is pinning.
    let ingest = Ingest(store: store, batchWindow: .seconds(60))
    let pumpA = await ingest.attach(connectionA, serverID: serverID)
    let pumpB = await ingest.attach(connectionB, serverID: serverID)

    await connectionA.start()
    await connectionB.start()
    // Every event was processed by BOTH connections: each watermark only
    // reaches its own batch's last timestamp once that specific event has
    // been recorded, in stream order. Waiting for genuine completion here
    // (rather than cancelling early) matters: `pumpA.cancel()` only stops
    // Ingest's collector, not `connectionA` itself, and cancelling before
    // production finished would leave the connection free to keep yielding
    // events nobody drains anymore -- a real, separate loss, but not the one
    // this test exists to catch.
    #expect(await waitUntil(timeout: .seconds(10)) {
        await connectionA.watermarkSnapshot().first?.lastMessageTime
            == Date(timeIntervalSince1970: TimeInterval(1_788_800_000 + total - 1))
    })
    #expect(await waitUntil(timeout: .seconds(10)) {
        await connectionB.watermarkSnapshot().first?.lastMessageTime
            == Date(timeIntervalSince1970: TimeInterval(1_788_900_000 + total - 1))
    })

    pumpA.cancel()
    pumpB.cancel()
    // No further waitUntil: awaiting both tasks to completion is itself the
    // guarantee under test -- once they return, every trailing flush they
    // made must have actually drained.
    await pumpA.value
    await pumpB.value
    #expect(try await store.messageCount() == total * 2)

    await connectionA.stop()
    await connectionB.stop()
}

/// Collects what the notify hook was handed, so a test can assert on it.
private actor StoredEventRecorder {
    private(set) var events: [NtfyEvent] = []
    private(set) var serverIDs: [UUID] = []

    func record(_ batch: [NtfyEvent], serverID: UUID) {
        events.append(contentsOf: batch)
        serverIDs.append(serverID)
    }
}

/// The notify hook fires on what `insert` actually **stored**, not on what the
/// stream delivered. Two consequences, both asserted here:
///
/// - A replayed duplicate raises nothing. A reconnect re-delivers the tail of
///   the cache, and every one of those messages was already stored — and
///   already notified — on its first pass. `insert` skips them, so they never
///   reach the hook.
/// - A non-message line raises nothing. `open` and `keepalive` are protocol,
///   with no title, body, or priority to present.
///
/// Feeding the hook the batch rather than `InsertResult.stored` would produce
/// all four ids here instead of the one.
@Test func theNotifyHookFiresOnlyForNewlyStoredMessages() async throws {
    let (_, store, serverID) = try makeServer()
    // Already in the archive before the stream ever runs — what a reconnect
    // replay looks like from the store's side.
    _ = try await store.insert([bufferEvent("already-stored", time: 1_788_800_000)],
                               serverID: serverID)

    let recorder = StoredEventRecorder()
    let fake = FakeStreamClient()
    await fake.enqueue([
        .event(try Fixtures.decode(Fixtures.openEvent)),
        .event(bufferEvent("already-stored", time: 1_788_800_000)),
        .event(bufferEvent("brand-new", time: 1_788_800_001)),
        .event(try Fixtures.decode(Fixtures.laterKeepaliveEvent)),
    ])

    let connection = ServerConnection(
        endpoint: NtfyEndpoint(baseURL: URL(string: "https://ntfy.example.com")!,
                               credential: .unauthenticated),
        watermarks: [TopicWatermark(topic: "alerts", lastMessageTime: nil)],
        client: fake, sleeper: ManualSleeper())

    let ingest = Ingest(store: store) { batch, id in
        await recorder.record(batch, serverID: id)
    }
    let pump = await ingest.attach(connection, serverID: serverID)
    defer { pump.cancel() }

    await connection.start()
    // `brand-new` is last of the four in stream order, so once it has been
    // recorded every earlier line has already been through a flush — the
    // assertion below cannot pass merely by being early.
    #expect(await waitUntil { await recorder.events.map(\.id) == ["brand-new"] })
    #expect(await recorder.serverIDs == [serverID])
    await connection.stop()
}
