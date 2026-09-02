import Foundation
import Testing
@testable import NtfyKit

private func connection(_ fake: FakeStreamClient,
                        watermarks: [TopicWatermark]) -> ServerConnection {
    ServerConnection(
        endpoint: NtfyEndpoint(baseURL: URL(string: "https://ntfy.example.com")!,
                               credential: .unauthenticated),
        watermarks: watermarks, client: fake, sleeper: ManualSleeper())
}

/// The gap must survive the .open that immediately follows it.
@Test func aHistoryGapIsDeliveredAsADiagnosticNotJustATransientState() async throws {
    let fake = FakeStreamClient()
    await fake.enqueue([.event(try Fixtures.decode(Fixtures.openEvent))])

    let stale = Date().addingTimeInterval(-48 * 3600)
    let c = connection(fake, watermarks: [TopicWatermark(topic: "alerts", lastMessageTime: stale)])

    let seen = DiagnosticCollector()
    let consumer = Task { for await d in c.diagnostics { await seen.add(d) } }
    defer { consumer.cancel() }

    await c.start()
    #expect(await waitUntil { await seen.contains { if case .historyGap = $0 { return true }; return false } })
    // The open line was processed — `caughtUpTo` is written only from a
    // stream line with `time > 0`, and `Fixtures.openEvent` carries
    // `time: 1788352812` — and the state machine has since run on to
    // `.backoff`, where `ManualSleeper` parks it forever. The diagnostic is
    // still readable at that point, which is the whole point: it outlived
    // both transitions. Asserted on `caughtUpTo` and `.backoff` rather than
    // pinned to `.open`: `FakeStreamClient`'s single-element script finishes
    // the instant `.open` is processed, and the run loop races through it to
    // `.backoff` before this line runs — `waitUntil`'s 10ms polling
    // granularity cannot reliably observe a transient that narrow (see
    // `reachesOpenStateAndEmitsMessages` in `ServerConnectionTests.swift`,
    // which hits the identical race against `MockNtfyServer` and works around
    // it by holding the connection open instead).
    #expect(await waitUntil { await c.caughtUpTo == Date(timeIntervalSince1970: 1_788_352_812) })
    #expect(await waitUntil { await c.state == .backoff(attempt: 1) })
    #expect(await seen.contains { if case .historyGap = $0 { return true }; return false })
    await c.stop()
}

@Test func noGapIsReportedForARecentWatermark() async throws {
    let fake = FakeStreamClient()
    await fake.enqueue([.event(try Fixtures.decode(Fixtures.openEvent))])
    let c = connection(fake, watermarks: [
        TopicWatermark(topic: "alerts", lastMessageTime: Date().addingTimeInterval(-60))])

    let seen = DiagnosticCollector()
    let consumer = Task { for await d in c.diagnostics { await seen.add(d) } }
    defer { consumer.cancel() }

    await c.start()
    // Proof the connection actually ran the resolve-and-connect path, rather
    // than pinning to `.open`: `FakeStreamClient`'s single-element script
    // finishes the instant `.open` is processed and the run loop races on to
    // `.backoff` before a 10ms-granularity `waitUntil` on `state` can
    // reliably catch it — see the identical fix in
    // `aHistoryGapIsDeliveredAsADiagnosticNotJustATransientState` above.
    // `requestCount` only advances once `stream(_:)` is actually invoked, so
    // it is a stable proxy for "resolution ran and produced a request".
    #expect(await waitUntil { await fake.requestCount >= 1 })
    try await Task.sleep(for: .milliseconds(50))
    #expect(await seen.contains { if case .historyGap = $0 { return true }; return false } == false)
    await c.stop()
}

@Test func theWatermarkSnapshotReflectsReceivedMessages() async throws {
    let fake = FakeStreamClient()
    await fake.enqueue([.event(try Fixtures.decode(Fixtures.minimalMessage))])
    let c = connection(fake, watermarks: [TopicWatermark(topic: "alerts", lastMessageTime: nil)])

    await c.start()
    #expect(await waitUntil { await c.watermarkSnapshot().first?.lastMessageTime != nil })
    #expect(await c.watermarkSnapshot().first?.lastMessageTime
            == Date(timeIntervalSince1970: 1_788_353_322))
    await c.stop()
}

actor DiagnosticCollector {
    private var items: [ConnectionDiagnostic] = []
    func add(_ d: ConnectionDiagnostic) { items.append(d) }
    func contains(_ predicate: (ConnectionDiagnostic) -> Bool) -> Bool { items.contains(where: predicate) }
}
