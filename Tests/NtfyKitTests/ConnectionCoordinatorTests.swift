import Foundation
import SwiftData
import Testing
@testable import NtfyKit

@Test func theStoreReportsItsServersAsSendableSnapshots() async throws {
    let container = try StoreFixtures.inMemoryContainer()
    let context = ModelContext(container)
    let a = Server(name: "Alpha", baseURLString: "https://a.example.com", sortOrder: 1)
    let b = Server(name: "Beta", baseURLString: "https://b.example.com", sortOrder: 0)
    context.insert(a); context.insert(b)
    context.insert(Subscription(topic: "alerts", server: a,
                                lastMessageTime: Date(timeIntervalSince1970: 100)))
    context.insert(Subscription(topic: "deploys", server: a))
    try context.save()

    let store = MessageStore(modelContainer: container)
    let servers = try await store.servers()

    #expect(servers.map(\.name) == ["Beta", "Alpha"])          // sortOrder, not insertion
    let alpha = try #require(servers.first { $0.name == "Alpha" })
    #expect(alpha.baseURL == URL(string: "https://a.example.com"))
    #expect(Set(alpha.topics) == ["alerts", "deploys"])
    #expect(alpha.watermarks.first { $0.topic == "alerts" }?.lastMessageTime
            == Date(timeIntervalSince1970: 100))
    #expect(alpha.watermarks.first { $0.topic == "deploys" }?.lastMessageTime == nil)
}

/// caughtUpTo must survive the round trip, or a restart replays every quiet
/// topic's whole cache — the defect Stage 3 exists to remove.
@Test func aServerSnapshotCarriesItsPersistedCaughtUpTo() async throws {
    let container = try StoreFixtures.inMemoryContainer()
    let id = UUID()
    let context = ModelContext(container)
    let server = Server(id: id, name: "Alpha", baseURLString: "https://a.example.com")
    context.insert(server)
    context.insert(Subscription(topic: "alerts", server: server))
    try context.save()

    let store = MessageStore(modelContainer: container)
    let mark = Date(timeIntervalSince1970: 1_788_353_322)
    try await store.setCaughtUpTo(mark, forServer: id)

    let snapshot = try #require(try await store.servers().first)
    #expect(snapshot.caughtUpTo == mark)
}

/// A server with a malformed URL is a corrupt row, not a crash.
@Test func aServerWithAnUnparseableURLIsSkippedNotFatal() async throws {
    let container = try StoreFixtures.inMemoryContainer()
    let context = ModelContext(container)
    context.insert(Server(name: "Broken", baseURLString: ""))
    let ok = Server(name: "Fine", baseURLString: "https://a.example.com")
    context.insert(ok)
    context.insert(Subscription(topic: "alerts", server: ok))
    try context.save()

    let servers = try await MessageStore(modelContainer: container).servers()
    #expect(servers.map(\.name) == ["Fine"])
}

private func seededStore(topics: [String] = ["alerts"]) throws -> (ModelContainer, UUID) {
    let container = try StoreFixtures.inMemoryContainer()
    let id = UUID()
    let context = ModelContext(container)
    let server = Server(id: id, name: "Alpha", baseURLString: "https://a.example.com")
    context.insert(server)
    for t in topics { context.insert(Subscription(topic: t, server: server)) }
    try context.save()
    return (container, id)
}

@Test func startingTheCoordinatorOpensOneConnectionPerServer() async throws {
    let (container, _) = try seededStore()
    let store = MessageStore(modelContainer: container)
    let fake = FakeStreamClient()
    await fake.enqueue([.event(try Fixtures.decode(Fixtures.openEvent))])

    let coordinator = ConnectionCoordinator(
        store: store, keychain: KeychainStore(service: "dev.aloi.NtfyMe.tests.\(UUID())"),
        client: fake, pathMonitor: FakePathMonitor(),
        ingest: Ingest(store: store))

    await coordinator.start()
    #expect(await waitUntil { await fake.requestCount >= 1 })
    #expect(await coordinator.connectionCount == 1)
    await coordinator.stop()
}

/// The whole point of Stage 3's caughtUpTo work: a restart must resume from the
/// persisted point, not replay from the oldest message.
@Test func aConnectionIsSeededWithThePersistedCaughtUpTo() async throws {
    let (container, id) = try seededStore()
    let store = MessageStore(modelContainer: container)
    // Watermark 24h old; caughtUpTo only 2 minutes old.
    let context = ModelContext(container)
    let sub = try #require(try context.fetch(FetchDescriptor<Subscription>()).first)
    sub.lastMessageTime = Date().addingTimeInterval(-86_400)
    try context.save()
    let recent = Date().addingTimeInterval(-120)
    try await store.setCaughtUpTo(recent, forServer: id)

    let fake = FakeStreamClient()
    await fake.enqueue([.event(try Fixtures.decode(Fixtures.openEvent))])
    let coordinator = ConnectionCoordinator(
        store: store, keychain: KeychainStore(service: "dev.aloi.NtfyMe.tests.\(UUID())"),
        client: fake, pathMonitor: FakePathMonitor(),
        ingest: Ingest(store: store))

    await coordinator.start()
    #expect(await waitUntil { await fake.requestCount >= 1 })

    let url = try #require(await fake.lastRequest?.url?.absoluteString)
    let since = Int(recent.timeIntervalSince1970) - 5
    #expect(url.contains("since=\(since)"))
    await coordinator.stop()
}

/// A network path coming back must reconnect immediately, not wait out backoff.
///
/// The first script hangs after `open` rather than finishing cleanly: a
/// script that finishes lets the connection's own backoff (base delay ~1s)
/// retry on its own well within `waitUntil`'s 5s timeout, which would pass
/// this test whether or not `pathMonitor.start`'s handler is actually wired
/// to `reconnectAll()`. Hanging means the only thing that can produce a
/// second request is `reconnectNow()` cancelling the stalled attempt.
@Test func aSatisfiedNetworkPathReconnectsEveryConnection() async throws {
    let (container, _) = try seededStore()
    let store = MessageStore(modelContainer: container)
    let fake = FakeStreamClient()
    await fake.enqueueThenHang([.event(try Fixtures.decode(Fixtures.openEvent))])
    let monitor = FakePathMonitor()

    let coordinator = ConnectionCoordinator(
        store: store, keychain: KeychainStore(service: "dev.aloi.NtfyMe.tests.\(UUID())"),
        client: fake, pathMonitor: monitor, ingest: Ingest(store: store))

    await coordinator.start()
    #expect(await waitUntil { await fake.requestCount >= 1 })
    let before = await fake.requestCount

    await fake.enqueue([.event(try Fixtures.decode(Fixtures.openEvent))])
    await monitor.simulatePathSatisfied()

    #expect(await waitUntil { await fake.requestCount > before })
    await coordinator.stop()
}

@Test func stoppingCancelsTheMonitorAndEveryConnection() async throws {
    let (container, id) = try seededStore()
    let store = MessageStore(modelContainer: container)
    let fake = FakeStreamClient()
    await fake.enqueue([.event(try Fixtures.decode(Fixtures.openEvent))])
    let monitor = FakePathMonitor()

    let coordinator = ConnectionCoordinator(
        store: store, keychain: KeychainStore(service: "dev.aloi.NtfyMe.tests.\(UUID())"),
        client: fake, pathMonitor: monitor, ingest: Ingest(store: store))
    await coordinator.start()
    #expect(await waitUntil { await fake.requestCount >= 1 })

    await coordinator.stop()
    #expect(await coordinator.connectionCount == 0)
    #expect(await waitUntil { await monitor.cancelCount == 1 })
    #expect(await coordinator.state(forServer: id) == nil)
}

/// `stop()`'s contract: once it returns, everything Ingest had already
/// received is durably persisted, not merely "will be, eventually." A caller
/// that quits or tears down the store right after `await coordinator.stop()`
/// must not lose a batch a pump was still holding.
///
/// The script ends cleanly after the message rather than hanging: the run
/// loop only starts a second connect attempt once it has fully processed
/// every already-buffered element from the first, so `requestCount >= 2` is
/// an ordering guarantee — not a timing guess — that the message was already
/// recorded and yielded onto `connection.events` before `stop()` is called.
@Test func stoppingWaitsForThePumpsFinalFlushBeforeReturning() async throws {
    let (container, _) = try seededStore()
    let store = MessageStore(modelContainer: container)
    let fake = FakeStreamClient()
    await fake.enqueue([
        .event(try Fixtures.decode(Fixtures.openEvent)),
        .event(try Fixtures.decode(Fixtures.minimalMessage)),
    ])

    // A window this test's own bound can't reach: only `stop()`'s own final
    // flush, never a tick, may be what persists this message.
    let ingest = Ingest(store: store, batchWindow: .seconds(60))
    let coordinator = ConnectionCoordinator(
        store: store, keychain: KeychainStore(service: "dev.aloi.NtfyMe.tests.\(UUID())"),
        client: fake, pathMonitor: FakePathMonitor(), ingest: ingest)

    await coordinator.start()
    #expect(await waitUntil { await fake.requestCount >= 2 })

    await coordinator.stop()
    // No waitUntil: `stop()` returning is itself the guarantee under test.
    #expect(try await store.messageCount() == 1)
}

private func seededTwoServerStore() throws -> (ModelContainer, UUID, UUID) {
    let container = try StoreFixtures.inMemoryContainer()
    let idA = UUID()
    let idB = UUID()
    let context = ModelContext(container)
    let serverA = Server(id: idA, name: "Alpha", baseURLString: "https://a.example.com", sortOrder: 0)
    let serverB = Server(id: idB, name: "Beta", baseURLString: "https://b.example.com", sortOrder: 1)
    context.insert(serverA); context.insert(serverB)
    context.insert(Subscription(topic: "alerts-a", server: serverA))
    context.insert(Subscription(topic: "alerts-b", server: serverB))
    try context.save()
    return (container, idA, idB)
}

private func bigBatch(_ prefix: String, count: Int, topic: String, base: Int) -> [NtfyStreamClient.StreamElement] {
    (0..<count).map { index in
        .event(NtfyEvent(
            id: "\(prefix)-\(index)", time: base + index, expires: nil,
            event: "message", topic: topic, title: nil, message: "m",
            priority: nil, tags: nil, click: nil, icon: nil, contentType: nil,
            actions: nil, attachment: nil))
    }
}

/// Two servers share one `Ingest` (`ConnectionCoordinator`'s own design: one
/// injected `Ingest` for every server it attaches). Their trailing flushes,
/// both triggered by the same `stop()` call, can genuinely race each other on
/// that shared actor — unlike a single connection's own collector, ticker,
/// and trailing calls, which `withTaskGroup` already serializes against each
/// other inside `Ingest.pump` (the group does not return until every child
/// task, including one mid-`store.insert`, has fully finished, so a lone
/// pump's own trailing flush can never itself observe a sibling call still in
/// flight). Two independent `pump()` invocations have no such structural
/// relationship, so before the fix, whichever trailing flush lost the race
/// for the shared serialization state skipped instead of draining, and
/// permanently dropped whatever its own buffer held at that moment.
@Test func stoppingDrainsBothServersEvenWhenTheirTrailingFlushesOverlap() async throws {
    let (container, _, _) = try seededTwoServerStore()
    let store = MessageStore(modelContainer: container)
    let fake = FakeStreamClient()

    // 3033, not 3000: the collector flushes on every 500-event ceiling, so a
    // round multiple would let the ceiling drain everything on its own,
    // leaving nothing for the trailing flush to prove. The 33-event
    // remainder past the last ceiling can ONLY ever be drained by a trailing
    // flush -- never a ceiling crossing -- so it is a *guaranteed*, not
    // merely likely, tail still sitting in each connection's buffer once
    // `stop()` is called.
    let total = 3033
    // Scripts end cleanly rather than hang: `requestCount >= 4` is then an
    // ordering guarantee, not a timing guess, that BOTH servers' entire
    // initial batch has already been fully processed by their own
    // `ServerConnection` and yielded onto `connection.events` -- each
    // connection only starts a next request once its current stream has
    // been drained to the end. Stopping before that would let the
    // not-yet-reached tail of a still-running connection be legitimately
    // abandoned by `connection.stop()` itself, which is a real but
    // different loss from the one this test exists to catch.
    await fake.enqueue(bigBatch("srv-a", count: total, topic: "alerts-a", base: 1_788_600_000))
    await fake.enqueue(bigBatch("srv-b", count: total, topic: "alerts-b", base: 1_788_700_000))

    // A window this test's own bound can't reach: with the ticker parked,
    // only ceiling crossings and the eventual trailing flush move any data,
    // so each connection's 33-event remainder is untouched by anything but
    // the race this test is pinning.
    let ingest = Ingest(store: store, batchWindow: .seconds(60))
    let coordinator = ConnectionCoordinator(
        store: store, keychain: KeychainStore(service: "dev.aloi.NtfyMe.tests.\(UUID())"),
        client: fake, pathMonitor: FakePathMonitor(), ingest: ingest)

    await coordinator.start()
    #expect(await waitUntil(timeout: .seconds(15)) { await fake.requestCount >= 4 })

    await coordinator.stop()
    // No further wait: `stop()` returning is itself the guarantee under test.
    #expect(try await store.messageCount() == total * 2)
}
