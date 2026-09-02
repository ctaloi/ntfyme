import Foundation

/// One-shot history fetch for a newly added topic (spec §5).
///
/// It must poll the single topic, not the shared multi-topic stream: a topic
/// with no watermark would otherwise drag the shared resume point to the epoch
/// and replay every other topic's entire cached history.
public struct Backfill: Sendable {
    public enum Error: Swift.Error, Equatable {
        /// The poll neither delivered its cache nor closed within the given
        /// timeout. Unlike a subscription's shared stream, a poll has no
        /// keepalives to prove it is merely quiet rather than stalled — a
        /// server that accepts the connection and then stops responding is
        /// indistinguishable from one that will never respond, so this must
        /// be bounded locally rather than trusted to a session-level timeout.
        case timedOut
    }

    private let endpoint: NtfyEndpoint
    private let client: any StreamClient
    private let store: MessageStore

    public init(endpoint: NtfyEndpoint, client: any StreamClient, store: MessageStore) {
        self.endpoint = endpoint
        self.client = client
        self.store = store
    }

    /// Fetches and stores the topic's server-cached history. Returns the number
    /// of rows inserted. Throws `Error.timedOut` if the poll has neither
    /// delivered its cache nor closed within `timeout` — in which case
    /// whatever events had already arrived are discarded, not partially
    /// inserted, and the topic's watermark is left untouched. A partial
    /// insert would advance the watermark past messages backfill never saw,
    /// silently hiding exactly the gap this task exists to avoid; discarding
    /// the whole batch instead makes a timed-out backfill a no-op the caller
    /// can safely retry.
    ///
    /// When the poll returns at least one message, the topic's watermark is
    /// set as a side effect of the insert (`MessageStore.advanceWatermarks`),
    /// which is what makes the subsequent stream rebuild safe for *this*
    /// topic. When the topic has no cached history at all, the insert has
    /// nothing to advance the watermark from and it stays `nil` — but that is
    /// still safe: `WatermarkResolver.resolve` ignores nil-watermark topics
    /// entirely (`ignoresTopicsThatHaveNoWatermarkYet`), so a never-synced
    /// topic cannot drag the shared resume point back regardless of whether
    /// backfill found anything for it.
    ///
    /// `timeout` is local to this call rather than delegated to the
    /// `StreamClient`'s session: a future session configured for long-lived
    /// subscriptions (large or unbounded resource timeouts) would otherwise
    /// leave a one-shot poll able to hang for as long as that session allows,
    /// which is the wrong bound for a request that is expected to return
    /// promptly or not at all.
    @discardableResult
    public func run(
        topic: String, serverID: UUID, timeout: Duration = .seconds(30)
    ) async throws -> Int {
        let request = try endpoint.pollRequest(topic: topic, since: .all)
        let events = try await collectEvents(from: request, timeout: timeout)

        let result = try await store.insert(events, serverID: serverID)
        Log.store.info("backfilled \(result.inserted, privacy: .public) messages for a new topic")
        return result.inserted
    }

    /// Races stream consumption against `timeout`. On expiry, cancels the
    /// consuming task — which, per `StreamClient`'s contract (mirrored by
    /// every implementation's `continuation.onTermination = { _ in
    /// task.cancel() }`), tears down the underlying request rather than
    /// leaving it running unobserved — and throws `.timedOut`.
    private func collectEvents(from request: URLRequest, timeout: Duration) async throws -> [NtfyEvent] {
        try await withThrowingTaskGroup(of: [NtfyEvent].self) { group in
            group.addTask {
                var events: [NtfyEvent] = []
                for try await element in client.stream(request) {
                    switch element {
                    case .event(let event):
                        if event.kind == .message { events.append(event) }
                    case .skippedLine(let reason):
                        Log.stream.warning("backfill skipped a line: \(reason, privacy: .public)")
                    }
                }
                return events
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw Error.timedOut
            }

            // Exactly two tasks were just added above and this is the first
            // `next()` call on this group, so a result is always available —
            // the force-unwrap reflects that structural guarantee, not an
            // assumption about the tasks' own outcomes.
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}
