import Foundation
import SwiftData
import Testing
@testable import NtfyKit

private func makeStore(topics: [String]) throws -> (ModelContainer, MessageStore, UUID) {
    let container = try StoreFixtures.inMemoryContainer()
    let serverID = UUID()
    let context = ModelContext(container)
    let server = Server(id: serverID, name: "Example", baseURLString: "https://ntfy.example.com")
    context.insert(server)
    for t in topics { context.insert(Subscription(topic: t, server: server)) }
    try context.save()
    return (container, MessageStore(modelContainer: container), serverID)
}

private func message(_ id: String, topic: String, time: Int) -> NtfyEvent {
    let json = """
    {"id":"\(id)","time":\(time),"event":"message","topic":"\(topic)","message":"m"}
    """
    return try! JSONDecoder().decode(NtfyEvent.self, from: Data(json.utf8))
}

@Test func backfillStoresTheTopicsCachedHistory() async throws {
    let (_, store, serverID) = try makeStore(topics: ["newtopic"])
    let fake = FakeStreamClient()
    await fake.enqueue([
        .event(message("h1", topic: "newtopic", time: 100)),
        .event(message("h2", topic: "newtopic", time: 200)),
    ])

    let backfill = Backfill(
        endpoint: NtfyEndpoint(baseURL: URL(string: "https://ntfy.example.com")!,
                               credential: .unauthenticated),
        client: fake, store: store)

    let inserted = try await backfill.run(topic: "newtopic", serverID: serverID)
    #expect(inserted == 2)
    #expect(try await store.messageCount() == 2)
}

/// It must be a one-shot POLL for that topic alone, not a shared stream —
/// otherwise it replays every other topic's history too.
@Test func backfillPollsOnlyTheOneTopic() async throws {
    let (_, store, serverID) = try makeStore(topics: ["newtopic", "other"])
    let fake = FakeStreamClient()
    await fake.enqueue([.event(message("h1", topic: "newtopic", time: 100))])

    let backfill = Backfill(
        endpoint: NtfyEndpoint(baseURL: URL(string: "https://ntfy.example.com")!,
                               credential: .unauthenticated),
        client: fake, store: store)
    _ = try await backfill.run(topic: "newtopic", serverID: serverID)

    let url = await fake.lastRequest?.url?.absoluteString ?? ""
    #expect(url.contains("/newtopic/json"))
    #expect(url.contains("poll=1"))
    #expect(url.contains("since=all"))
    #expect(url.contains("other") == false)
}

/// After backfill the topic has a watermark, so the rebuilt shared stream
/// cannot drag the resume point to the epoch.
@Test func backfillLeavesTheTopicWithAWatermark() async throws {
    let (_, store, serverID) = try makeStore(topics: ["newtopic"])
    let fake = FakeStreamClient()
    await fake.enqueue([.event(message("h1", topic: "newtopic", time: 100)),
                        .event(message("h2", topic: "newtopic", time: 250))])

    let backfill = Backfill(
        endpoint: NtfyEndpoint(baseURL: URL(string: "https://ntfy.example.com")!,
                               credential: .unauthenticated),
        client: fake, store: store)
    _ = try await backfill.run(topic: "newtopic", serverID: serverID)

    let marks = try await store.watermarks(forServer: serverID)
    #expect(marks.first(where: { $0.topic == "newtopic" })?.lastMessageTime
            == Date(timeIntervalSince1970: 250))
}
