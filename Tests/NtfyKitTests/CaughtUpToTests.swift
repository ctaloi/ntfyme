import Foundation
import Testing
@testable import NtfyKit

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let window: TimeInterval = 12 * 3600

private func wm(_ topic: String, _ offset: TimeInterval?) -> TopicWatermark {
    TopicWatermark(topic: topic, lastMessageTime: offset.map { now.addingTimeInterval($0) })
}

/// The whole point of §5.2: a topic quiet for longer than the cache window
/// must not drag the resume point out of the window when the connection was
/// demonstrably caught up more recently.
@Test func aQuietTopicDoesNotDragTheResumePointOutOfTheWindow() {
    let r = WatermarkResolver.resolve(
        watermarks: [wm("quiet", -(window + 7200)), wm("busy", -60)],
        caughtUpTo: now.addingTimeInterval(-120),
        cacheWindow: window, now: now, margin: 5
    )
    #expect(r.since == .unixTime(Int(now.timeIntervalSince1970) - 120 - 5))
    #expect(r.hasHistoryGap == false)
}

/// A genuinely long disconnect still reports a gap: caughtUpTo is old too.
@Test func aRealLongDisconnectStillReportsAGap() {
    let r = WatermarkResolver.resolve(
        watermarks: [wm("a", -(window + 7200))],
        caughtUpTo: now.addingTimeInterval(-(window + 3600)),
        cacheWindow: window, now: now, margin: 5
    )
    #expect(r.hasHistoryGap == true)
}

/// caughtUpTo never moves the resume point FORWARD past an unread message.
/// If a topic's watermark is newer, the max() picks caughtUpTo only when it
/// is later than the oldest watermark — never later than the newest.
@Test func caughtUpToNeverSkipsPastAnOlderWatermarkThatIsStillInWindow() {
    let r = WatermarkResolver.resolve(
        watermarks: [wm("a", -600), wm("b", -300)],
        caughtUpTo: now.addingTimeInterval(-900),
        cacheWindow: window, now: now, margin: 5
    )
    // caughtUpTo (-900) is older than min watermark (-600), so min wins.
    #expect(r.since == .unixTime(Int(now.timeIntervalSince1970) - 600 - 5))
}

@Test func nilCaughtUpToBehavesExactlyAsBefore() {
    let r = WatermarkResolver.resolve(
        watermarks: [wm("a", -600), wm("b", -120)],
        caughtUpTo: nil,
        cacheWindow: window, now: now, margin: 5
    )
    #expect(r.since == .unixTime(Int(now.timeIntervalSince1970) - 600 - 5))
}

@Test func caughtUpToAloneResolvesWhenNoTopicHasAWatermark() {
    let r = WatermarkResolver.resolve(
        watermarks: [wm("a", nil)],
        caughtUpTo: now.addingTimeInterval(-90),
        cacheWindow: window, now: now, margin: 5
    )
    #expect(r.since == .unixTime(Int(now.timeIntervalSince1970) - 90 - 5))
}

/// ntfy sends the `open` line *before* it replays cached history — its
/// subscribe handler calls `sub(v, NewOpenMessage(...))` and only then
/// `sendOldMessages(...)` — and `open` carries `time = now`. So `open` proves
/// the replay has *not started*, not that it finished, and a socket drop
/// mid-replay must leave the resume point at the newest message actually
/// received rather than at the open line's clock reading.
///
/// The numbers are the shape of a real replay: `openEvent` is t=1788352812
/// (the server's "now") and `richMessage` is t=1788335966, ~4.7 hours older.
/// Treating `open` as a delivery proof resolved the reconnect to
/// `since=1788352807` and skipped that whole window, with no history gap
/// reported — the loss was silent.
@Test func aDropMidReplayResumesFromTheMessageNotTheOpenLine() async throws {
    let fake = FakeStreamClient()
    await fake.enqueue([
        .event(try Fixtures.decode(Fixtures.openEvent)),
        .event(try Fixtures.decode(Fixtures.richMessage)),
    ])

    let connection = ServerConnection(
        endpoint: NtfyEndpoint(baseURL: URL(string: "https://ntfy.example.com")!,
                               credential: .unauthenticated),
        watermarks: [TopicWatermark(topic: "alerts", lastMessageTime: nil)],
        client: fake,
        sleeper: ManualSleeper()
    )
    await connection.start()

    // The script has no keepalive, so nothing in it ever proved the replay
    // completed. `.backoff(attempt: 1)` is the proof that the first attempt
    // ran to its end of stream, so both lines have been processed by now.
    #expect(await waitUntil { await connection.state == .backoff(attempt: 1) })
    #expect(await connection.caughtUpTo == nil)

    await connection.reconnectNow()
    #expect(await waitUntil { await fake.requestCount == 2 })
    let url = await fake.lastRequest?.url?.absoluteString ?? ""
    // 1788335966 − 5s margin. NOT 1788352807, which is the open line's time.
    #expect(url.contains("since=1788335961"))
    await connection.stop()
}

/// The persisted `caughtUpTo` has to be able to reach the resolver, or §5.2
/// only ever applies within a single process. Before `init` took it, every
/// launch resolved `max(min(watermarks), nil)` — the pre-§5.2 rule — so a
/// topic that was merely quiet for longer than the cache window produced a
/// full-cache replay and a false history gap on *every* app start.
///
/// The watermark here is 24 hours old against a 12-hour window, so the naive
/// rule would both resolve `since` to it and report a gap. The seeded resume
/// point is two minutes old, so the correct answer does neither.
@Test func aSeededCaughtUpToDrivesTheFirstRequest() async throws {
    let fake = FakeStreamClient()
    // Hangs rather than finishing, so the connection cannot reconnect and
    // the request under test is unambiguously the first one.
    await fake.enqueueHang()

    let quiet = Date().addingTimeInterval(-24 * 3600)
    let resumed = Date().addingTimeInterval(-120)

    let connection = ServerConnection(
        endpoint: NtfyEndpoint(baseURL: URL(string: "https://ntfy.example.com")!,
                               credential: .unauthenticated),
        watermarks: [TopicWatermark(topic: "alerts", lastMessageTime: quiet)],
        caughtUpTo: resumed,
        client: fake,
        sleeper: ManualSleeper()
    )

    let seen = DiagnosticCollector()
    let consumer = Task { for await d in connection.diagnostics { await seen.add(d) } }
    defer { consumer.cancel() }

    await connection.start()
    #expect(await waitUntil { await fake.requestCount == 1 })

    let expected = Int(resumed.addingTimeInterval(-5).timeIntervalSince1970.rounded(.down))
    let url = await fake.lastRequest?.url?.absoluteString ?? ""
    #expect(url.contains("since=\(expected)"))
    #expect(await seen.contains { if case .historyGap = $0 { return true }; return false } == false)
    await connection.stop()
}

/// A keepalive carries no message but does advance the resume point.
@Test func aKeepaliveAdvancesCaughtUpTo() async throws {
    let fake = FakeStreamClient()
    await fake.enqueue([
        .event(try Fixtures.decode(Fixtures.openEvent)),
        .event(try Fixtures.decode(Fixtures.keepaliveEvent)),
    ])

    let connection = ServerConnection(
        endpoint: NtfyEndpoint(baseURL: URL(string: "https://ntfy.example.com")!,
                               credential: .unauthenticated),
        watermarks: [TopicWatermark(topic: "alerts", lastMessageTime: nil)],
        client: fake,
        sleeper: ManualSleeper()
    )
    await connection.start()
    #expect(await waitUntil { await connection.caughtUpTo != nil })
    // keepaliveEvent's time is 1788352857.
    #expect(await connection.caughtUpTo == Date(timeIntervalSince1970: 1_788_352_857))
    await connection.stop()
}
