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
        /// True when the resume point this resolution actually asks for —
        /// `max(min(watermarks), caughtUpTo) − margin`, i.e. the value in
        /// `since` — predates the server's cache window, so some messages are
        /// unrecoverable and the caller must surface it.
        ///
        /// Not "the oldest watermark predates the cache window", which is what
        /// this said before §5.2 landed. Two things changed. A topic that was
        /// merely quiet no longer drags the measurement out of the window on
        /// its own, because `caughtUpTo` can be newer than its watermark; and
        /// the margin is included, because a resume point inside the window
        /// can still produce a `since` outside it.
        public let hasHistoryGap: Bool
    }

    public static func resolve(
        watermarks: [TopicWatermark],
        caughtUpTo: Date? = nil,
        cacheWindow: TimeInterval,
        now: Date = Date(),
        margin: TimeInterval = 5
    ) -> Resolution {
        // §5.2: the resume point is "everything up to here has been delivered",
        // not "the oldest message we happen to hold". A topic that was merely
        // quiet must not drag the resume point out of the server's cache
        // window.
        //
        // `caughtUpTo` is the delivery proof, and **only a `keepalive` line
        // carries it** — see §5.2 and `ServerConnection.caughtUpTo`. ntfy emits
        // keepalives only after `sendOldMessages` returns; the `open` line
        // carries `time = now` and is sent *before* the replay it announces, so
        // it proves the replay has not started rather than that it finished.
        // An earlier revision of this comment said "any line (open or
        // keepalive)", which is the claim that let a drop mid-replay advance
        // the resume point past history the server had not yet sent.
        let oldestMessage = watermarks.compactMap(\.lastMessageTime).min()

        let resumeFrom: Date?
        switch (oldestMessage, caughtUpTo) {
        case (nil, nil):        resumeFrom = nil
        case (let m?, nil):     resumeFrom = m
        case (nil, let c?):     resumeFrom = c
        case (let m?, let c?):  resumeFrom = max(m, c)
        }

        guard let resumeFrom else {
            return Resolution(since: .all, hasHistoryGap: false)
        }

        // The gap is measured from the value actually sent to the server
        // (resumeFrom - margin), not from `resumeFrom` itself. The margin
        // exists to pull `since` slightly earlier than the resume point — the
        // resume point, not "the watermark": since §5.2 it is equally often
        // `caughtUpTo` — so a message landing exactly on the boundary isn't
        // missed. But that same shift can push `since` past the cache window
        // even when `resumeFrom` sits inside it. Measuring from `resumeFrom`
        // would report a clean resume in that sliver while the server silently
        // replays its whole cache.
        let sinceDate = resumeFrom.addingTimeInterval(-margin)
        let gap = now.timeIntervalSince(sinceDate) > cacheWindow
        return Resolution(
            since: .unixTime(Int(sinceDate.timeIntervalSince1970.rounded(.down))),
            hasHistoryGap: gap
        )
    }
}
