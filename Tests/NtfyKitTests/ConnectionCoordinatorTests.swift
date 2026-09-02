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
