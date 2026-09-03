import Foundation
import SwiftData
import Testing
@testable import NtfyKit

/// `sync()` exists because a subscription is fixed when the stream opens, so a
/// server or topic added through the app's own Settings never reached the
/// connection layer until the next launch: the entire first-run path produced
/// no messages, no error, and no hint that a relaunch was needed.

private func emptyStore() throws -> MessageStore {
    MessageStore(modelContainer: try StoreFixtures.inMemoryContainer())
}

private func makeCoordinator(_ store: MessageStore, client: FakeStreamClient)
    -> ConnectionCoordinator {
    ConnectionCoordinator(
        store: store,
        keychain: KeychainStore(service: "dev.aloi.NtfyMe.tests.\(UUID())"),
        client: client, pathMonitor: FakePathMonitor(),
        ingest: Ingest(store: store))
}

@Test func syncOpensAServerAddedAfterStart() async throws {
    let store = try emptyStore()
    let fake = FakeStreamClient()
    await fake.enqueueThenHang([.event(try Fixtures.decode(Fixtures.openEvent))])
    let coordinator = makeCoordinator(store, client: fake)

    await coordinator.start()
    #expect(await coordinator.connectionCount == 0, "nothing configured yet")

    // Exactly what SettingsModel does when the user adds a server.
    let id = try await store.addServer(
        name: "Home Lab", baseURL: URL(string: "https://example.invalid")!,
        authKindRaw: "none")
    try await store.addTopic("alerts", toServer: id)

    await coordinator.sync()
    #expect(await coordinator.connectionCount == 1,
            "a server added through Settings must connect without a relaunch")
    await coordinator.stop()
}

/// A server with no topics has nothing to subscribe to, so adding the server
/// alone must not open a connection — only adding its first topic does.
@Test func syncIgnoresAServerWithNoTopicsUntilOneIsAdded() async throws {
    let store = try emptyStore()
    let fake = FakeStreamClient()
    await fake.enqueueThenHang([.event(try Fixtures.decode(Fixtures.openEvent))])
    let coordinator = makeCoordinator(store, client: fake)
    await coordinator.start()

    let id = try await store.addServer(
        name: "Home Lab", baseURL: URL(string: "https://example.invalid")!,
        authKindRaw: "none")
    await coordinator.sync()
    #expect(await coordinator.connectionCount == 0)

    try await store.addTopic("alerts", toServer: id)
    await coordinator.sync()
    #expect(await coordinator.connectionCount == 1)
    await coordinator.stop()
}

/// The removal half, which is the data-correctness one: a removed server's
/// connection kept inserting rows keyed to a server row that no longer
/// existed. Those rows were visible in History and the popover, still raised
/// notifications, and could never be removed again because `removeServer`
/// early-returns on an unknown id.
@Test func syncStopsAConnectionWhoseServerWasRemoved() async throws {
    let store = try emptyStore()
    let fake = FakeStreamClient()
    await fake.enqueueThenHang([.event(try Fixtures.decode(Fixtures.openEvent))])
    let coordinator = makeCoordinator(store, client: fake)

    let id = try await store.addServer(
        name: "Home Lab", baseURL: URL(string: "https://example.invalid")!,
        authKindRaw: "none")
    try await store.addTopic("alerts", toServer: id)
    await coordinator.start()
    #expect(await coordinator.connectionCount == 1)

    try await store.removeServer(id, attachmentsDirectory: nil)
    await coordinator.sync()
    #expect(await coordinator.connectionCount == 0,
            "a removed server must stop streaming, or it keeps inserting orphan rows")
    await coordinator.stop()
}

/// Removing the last topic leaves the server configured but with nothing to
/// subscribe to, which is the same "nothing to stream" state as no server.
@Test func syncStopsAConnectionWhoseLastTopicWasRemoved() async throws {
    let store = try emptyStore()
    let fake = FakeStreamClient()
    await fake.enqueueThenHang([.event(try Fixtures.decode(Fixtures.openEvent))])
    let coordinator = makeCoordinator(store, client: fake)

    let id = try await store.addServer(
        name: "Home Lab", baseURL: URL(string: "https://example.invalid")!,
        authKindRaw: "none")
    try await store.addTopic("alerts", toServer: id)
    await coordinator.start()
    #expect(await coordinator.connectionCount == 1)

    try await store.removeTopic("alerts", fromServer: id)
    await coordinator.sync()
    #expect(await coordinator.connectionCount == 0)
    await coordinator.stop()
}

/// Calling it with nothing changed must not churn connections — otherwise
/// every Settings edit would tear down and re-establish every stream, and
/// re-request each replay window.
@Test func syncIsAQuietNoOpWhenNothingChanged() async throws {
    let store = try emptyStore()
    let fake = FakeStreamClient()
    await fake.enqueueThenHang([.event(try Fixtures.decode(Fixtures.openEvent))])
    let coordinator = makeCoordinator(store, client: fake)

    let id = try await store.addServer(
        name: "Home Lab", baseURL: URL(string: "https://example.invalid")!,
        authKindRaw: "none")
    try await store.addTopic("alerts", toServer: id)
    await coordinator.start()

    await coordinator.sync()
    await coordinator.sync()
    #expect(await coordinator.connectionCount == 1)
    await coordinator.stop()
}

// MARK: - Backfill

/// `Backfill`'s whole reason to exist: the shared multi-topic stream
/// deliberately excludes a nil-watermark topic from its resume point (see
/// `Backfill`'s own doc comment), so nothing else ever fetches a brand-new
/// topic's server-cached history — `open` firing one for the topic itself
/// is the only thing that does.
@Test func openBackfillsATopicWithNoWatermarkYet() async throws {
    let store = try emptyStore()
    let fake = FakeStreamClient()
    // First `stream()` call: the live connection's own subscribe, held open
    // so it cannot also retry and consume the backfill's script below.
    await fake.enqueueThenHang([.event(try Fixtures.decode(Fixtures.openEvent))])
    // Second `stream()` call: `Backfill`'s one-shot poll for "alerts", the
    // topic just added — no watermark yet, since it was never subscribed to
    // before this test added it.
    await fake.enqueue([.event(try Fixtures.decode(Fixtures.minimalMessage))])
    let coordinator = makeCoordinator(store, client: fake)

    let id = try await store.addServer(
        name: "Home Lab", baseURL: URL(string: "https://example.invalid")!,
        authKindRaw: "none")
    try await store.addTopic("alerts", toServer: id)

    await coordinator.start()
    #expect(await coordinator.connectionCount == 1)

    // Runs as a background task alongside the connection, not before it —
    // polled rather than asserted immediately after `start()` returns.
    let backfilled = await waitUntil { (try? await store.messageCount()) == 1 }
    #expect(backfilled)
    await coordinator.stop()
}

/// `stop()`'s contract — nothing still writing once it returns — extends to
/// backfill tasks, not just pumps: a poll that never completes on its own
/// must not leave `stop()` waiting on it forever, and must not still be
/// running after `stop()` has already returned either. Both require the
/// same pairing `stop()` gives pumps: cancel, then await.
@Test func stopCancelsAndAwaitsAnInFlightBackfillPoll() async throws {
    let store = try emptyStore()
    let fake = FakeStreamClient()
    await fake.enqueueThenHang([.event(try Fixtures.decode(Fixtures.openEvent))])
    // Never finishes on its own — only cancellation ends it, the same
    // technique `aSatisfiedNetworkPathReconnectsEveryConnection` and others
    // in `ConnectionCoordinatorTests.swift` use to prove a stall is actually
    // being interrupted, not merely outrun by a fast, cleanly-ending script.
    await fake.enqueueHang()
    let coordinator = makeCoordinator(store, client: fake)

    let id = try await store.addServer(
        name: "Home Lab", baseURL: URL(string: "https://example.invalid")!,
        authKindRaw: "none")
    try await store.addTopic("alerts", toServer: id)
    await coordinator.start()

    // Confirms the backfill's poll has actually reached `client.stream()`
    // and is now hung — not merely scheduled — before `stop()` is called,
    // so this exercises cancelling in-flight work, not just skipping work
    // that had not started yet.
    #expect(await waitUntil { await fake.requestCount >= 2 })

    // If `stop()` failed to cancel the hanging backfill task, this call
    // would never return — the test would hang rather than fail with a
    // clean assertion, the same tradeoff
    // `stoppingCancelsTheMonitorAndEveryConnection` already accepts
    // elsewhere in this suite for the equivalent pump-hang case.
    await coordinator.stop()
    #expect(await coordinator.connectionCount == 0)
}
