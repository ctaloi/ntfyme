import Foundation
import Testing
@testable import NtfyKit

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let window: TimeInterval = 12 * 3600

private func wm(_ topic: String, _ offset: TimeInterval?) -> TopicWatermark {
    TopicWatermark(topic: topic, lastMessageTime: offset.map { now.addingTimeInterval($0) })
}

/// No watermark anywhere: a fresh install must not replay the world.
@Test func resolvesToAllWhenNothingHasAWatermark() {
    let r = WatermarkResolver.resolve(watermarks: [wm("a", nil), wm("b", nil)], caughtUpTo: nil, cacheWindow: window, now: now)
    #expect(r.since == .all)
    #expect(r.hasHistoryGap == false)
}

/// The oldest watermark wins, minus the boundary margin.
@Test func resolvesToTheOldestWatermarkMinusMargin() {
    let r = WatermarkResolver.resolve(
        watermarks: [wm("a", -600), wm("b", -120)],
        caughtUpTo: nil,
        cacheWindow: window, now: now, margin: 5
    )
    #expect(r.since == .unixTime(Int(now.timeIntervalSince1970) - 600 - 5))
}

/// A topic with no watermark yet is backfilled separately (spec §5). It must
/// not drag the shared minimum to zero and replay every other topic.
@Test func ignoresTopicsThatHaveNoWatermarkYet() {
    let r = WatermarkResolver.resolve(
        watermarks: [wm("a", -600), wm("new", nil)],
        caughtUpTo: nil,
        cacheWindow: window, now: now, margin: 5
    )
    #expect(r.since == .unixTime(Int(now.timeIntervalSince1970) - 600 - 5))
}

/// Older than the server's cache window: the server will silently return the
/// whole cache. The client already knows, and must say so.
@Test func flagsAHistoryGapWhenTheWatermarkPredatesTheCacheWindow() {
    let r = WatermarkResolver.resolve(
        watermarks: [wm("a", -(window + 3600))],
        caughtUpTo: nil,
        cacheWindow: window, now: now, margin: 5
    )
    #expect(r.hasHistoryGap == true)
}

@Test func doesNotFlagAGapForARecentWatermark() {
    let r = WatermarkResolver.resolve(watermarks: [wm("a", -60)], caughtUpTo: nil, cacheWindow: window, now: now)
    #expect(r.hasHistoryGap == false)
}

/// The boundary sliver: a watermark inside the cache window whose `since`
/// value — watermark minus margin — falls outside it.
@Test func flagsAGapWhenTheMarginPushesSinceOutsideTheWindow() {
    let r = WatermarkResolver.resolve(
        watermarks: [wm("a", -(window - 2))],
        caughtUpTo: nil,
        cacheWindow: window, now: now, margin: 5
    )
    #expect(r.hasHistoryGap == true)
}

@Test func resolvesToAllForAnEmptyTopicSet() {
    let r = WatermarkResolver.resolve(watermarks: [], caughtUpTo: nil, cacheWindow: window, now: now)
    #expect(r.since == .all)
}
