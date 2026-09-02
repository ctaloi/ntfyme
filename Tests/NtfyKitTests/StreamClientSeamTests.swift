import Foundation
import Testing
@testable import NtfyKit

@Test func connectionDrivesEventsFromAnInjectedClient() async throws {
    let fake = FakeStreamClient()
    await fake.enqueue([
        .event(try Fixtures.decode(Fixtures.openEvent)),
        .event(try Fixtures.decode(Fixtures.minimalMessage)),
    ])

    let connection = ServerConnection(
        endpoint: NtfyEndpoint(baseURL: URL(string: "https://ntfy.example.com")!,
                               credential: .unauthenticated),
        watermarks: [TopicWatermark(topic: "alerts", lastMessageTime: nil)],
        client: fake,
        sleeper: ManualSleeper()
    )

    let received = Collector()
    let consumer = Task { for await event in connection.events { await received.add(event) } }
    defer { consumer.cancel() }

    await connection.start()
    #expect(await waitUntil { await received.count == 1 })
    #expect(await received.first?.message == "A1")
    await connection.stop()
}

/// No socket, no polling for a port: the whole exchange is in-process.
@Test func theFakeClientRecordsTheRequestItWasGiven() async throws {
    let fake = FakeStreamClient()
    await fake.enqueue([.event(try Fixtures.decode(Fixtures.openEvent))])

    let connection = ServerConnection(
        endpoint: NtfyEndpoint(baseURL: URL(string: "https://ntfy.example.com")!,
                               credential: .unauthenticated),
        watermarks: [TopicWatermark(topic: "alerts", lastMessageTime: nil)],
        client: fake,
        sleeper: ManualSleeper()
    )
    await connection.start()
    #expect(await waitUntil { await fake.requestCount == 1 })
    #expect(await fake.lastRequest?.url?.absoluteString.hasPrefix("https://ntfy.example.com/alerts/json") == true)
    await connection.stop()
}
