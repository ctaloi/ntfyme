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
    /// Same hook `Ingest` calls after its own flush, so a backfilled batch
    /// reaches the same app-layer seam a live-stream batch does — the
    /// attachment fetcher and the unread badge must not care which path
    /// wrote a row. Called with `.backfill`, not `.stream`: see
    /// `Ingest.StoredSource`'s doc comment for why the app layer is
    /// expected to skip a notification banner for this source specifically
    /// while still acting on everything else.
    private let onStored: Ingest.StoredHandler?

    public init(endpoint: NtfyEndpoint, client: any StreamClient, store: MessageStore,
                onStored: Ingest.StoredHandler? = nil) {
        self.endpoint = endpoint
        self.client = client
        self.store = store
        self.onStored = onStored
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
    /// The same guarantee holds for **external cancellation**, which is how a
    /// coordinator will actually abandon a backfill — the user removes the
    /// topic, or the app quits. It throws `CancellationError` and inserts
    /// nothing. This needs its own enforcement rather than falling out of the
    /// timeout path: cancelling the collector ends its `for try await`
    /// cleanly, with no throw, so it would otherwise return the partial batch
    /// it had already gathered.
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

        // The collector child already refuses to hand back a partial batch it
        // was cancelled out of, so this is the second of two checks rather
        // than the only one. It is worth having: `collectEvents` can also
        // return a *complete* batch on the same turn a cancellation lands,
        // and an abandoned backfill must not write in that case either.
        try Task.checkCancellation()
        let result = try await store.insert(events, serverID: serverID)
        Log.store.info("backfilled \(result.inserted, privacy: .public) messages for a new topic")

        // Same "only if non-empty" guard `Ingest.performFlush` applies to its
        // own call of this hook — a backfill that found nothing new has
        // nothing for the attachment fetcher or the badge to act on either.
        if let onStored, !result.stored.isEmpty {
            await onStored(result.stored, serverID, .backfill)
        }
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
                // External cancellation ends the `for try await` above
                // *cleanly* — `next()` returns nil, nothing throws — so
                // without this the child returns its partial array and races
                // the sleeper child's `CancellationError` for `group.next()`.
                // Whichever lands first decides whether a cancelled backfill
                // inserts a partial batch, which is not a decision a coin
                // flip may make.
                try Task.checkCancellation()
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
