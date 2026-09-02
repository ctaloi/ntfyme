import Foundation

/// One topic's resume position on a server.
public struct TopicWatermark: Sendable, Equatable {
    public let topic: String
    /// Server-provided timestamp of the newest message seen. `nil` means this
    /// topic has never been synced and is backfilled separately.
    public let lastMessageTime: Date?

    public init(topic: String, lastMessageTime: Date?) {
        self.topic = topic
        self.lastMessageTime = lastMessageTime
    }
}

/// Computes the single `since=` value for a shared multi-topic connection.
///
/// Timestamps are used rather than message IDs deliberately. Both are correct
/// given deduplication, but an unresolvable message ID returns HTTP 200 with a
/// full cache replay — indistinguishable from a clean resume. A timestamp lets
/// the client detect the same situation before it sends the request, which is
/// what `hasHistoryGap` reports.
public enum WatermarkResolver {
    public struct Resolution: Sendable, Equatable {
        public let since: SinceParameter
        /// True when the oldest watermark predates the server's cache window,
        /// so some messages are unrecoverable and the caller must surface it.
        public let hasHistoryGap: Bool
    }

    public static func resolve(
        watermarks: [TopicWatermark],
        cacheWindow: TimeInterval,
        now: Date = Date(),
        margin: TimeInterval = 5
    ) -> Resolution {
        let times = watermarks.compactMap(\.lastMessageTime)
        guard let oldest = times.min() else {
            return Resolution(since: .all, hasHistoryGap: false)
        }

        // The gap is measured from the value actually sent to the server
        // (oldest - margin), not from `oldest` itself. The margin exists to
        // pull `since` slightly earlier than the watermark so a message
        // landing exactly on the boundary isn't missed — but that same shift
        // can push `since` past the cache window even when `oldest` sits
        // inside it. Measuring from `oldest` would report a clean resume in
        // that sliver while the server silently replays its whole cache.
        let sinceDate = oldest.addingTimeInterval(-margin)
        let gap = now.timeIntervalSince(sinceDate) > cacheWindow
        return Resolution(since: .unixTime(Int(sinceDate.timeIntervalSince1970.rounded(.down))), hasHistoryGap: gap)
    }
}
