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
    await connection.stop()
}
