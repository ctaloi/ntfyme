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

/// After a successful backfill the topic has a watermark, so the rebuilt
/// shared stream resumes it from that point instead of missing everything
/// that came before. (When backfill finds nothing for a topic the watermark
/// stays `nil` instead — separately safe, see
/// `backfillOfATopicWithNoCachedHistoryLeavesTheWatermarkNil` below and
/// `WatermarkResolver`'s `ignoresTopicsThatHaveNoWatermarkYet`.)
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

/// A topic with no cached history at all (nothing was ever posted, or it all
/// expired out of the server's cache window) must not crash and must not
/// fabricate a watermark. `WatermarkResolver.resolve` already ignores
/// nil-watermark topics when computing the shared resume point
/// (`ignoresTopicsThatHaveNoWatermarkYet`), so leaving it `nil` here is safe,
/// not merely tolerated.
@Test func backfillOfATopicWithNoCachedHistoryLeavesTheWatermarkNil() async throws {
    let (_, store, serverID) = try makeStore(topics: ["newtopic"])
    let fake = FakeStreamClient()
    await fake.enqueue([])

    let backfill = Backfill(
        endpoint: NtfyEndpoint(baseURL: URL(string: "https://ntfy.example.com")!,
                               credential: .unauthenticated),
        client: fake, store: store)
    let inserted = try await backfill.run(topic: "newtopic", serverID: serverID)

    #expect(inserted == 0)
    let marks = try await store.watermarks(forServer: serverID)
    #expect(marks.first(where: { $0.topic == "newtopic" })?.lastMessageTime == nil)
}

/// A server that accepts the connection and then never responds — no data,
/// no close — must not hang backfill forever. Unlike a subscription's shared
/// stream, a poll has no keepalives to prove it's merely quiet, so this bound
/// must come from `Backfill` itself, not from the underlying session.
///
/// `.timeLimit` is the test's own bound, distinct from the `timeout` passed
/// to `run` below: without it, a regression that removed `run`'s internal
/// race would hang this test itself rather than fail it — exactly the
/// failure mode this test exists to catch, one level up.
@Test(.timeLimit(.minutes(1)))
func backfillTimesOutRatherThanHangingOnAStalledPoll() async throws {
    let (_, store, serverID) = try makeStore(topics: ["newtopic"])
    let fake = FakeStreamClient()
    await fake.enqueueHang()

    let backfill = Backfill(
        endpoint: NtfyEndpoint(baseURL: URL(string: "https://ntfy.example.com")!,
                               credential: .unauthenticated),
        client: fake, store: store)

    await #expect(throws: Backfill.Error.timedOut) {
        try await backfill.run(topic: "newtopic", serverID: serverID, timeout: .milliseconds(50))
    }
}
