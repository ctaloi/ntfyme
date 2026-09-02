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
