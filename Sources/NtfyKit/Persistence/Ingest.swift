import Foundation

/// Drains a connection's event stream into the store.
///
/// Events are batched over a short window rather than written one at a time:
/// a reconnect replay can deliver thousands of lines at once, and one
/// transaction per message would be pathological.
///
/// **Resume state advances on persisted, not on received** (spec §5.2). The
/// `caughtUpTo` this writes is derived from the batch that was just durably
/// stored — the newest keepalive *in that batch* — never from a cross-actor
/// read of `ServerConnection.caughtUpTo`. Two failures follow from getting
/// that wrong, and both are permanent archive loss no reconnect repairs:
///
/// - A batch whose insert fails, dropped while the resume point moves past it
///   anyway. It is now kept in the buffer and retried on the next tick.
/// - A resume point read *after* a long insert, by which time the connection
///   has seen lines covering events still sitting in this actor's buffer or
///   in the stream's. Deriving from the batch removes the read entirely.
public actor Ingest {
    /// Called with the messages a flush **actually stored**, and the server
    /// they belong to. This is the seam the app target notifies from.
    ///
    /// `[NtfyEvent]`, not `[MessageSnapshot]`: the events are already in
    /// hand here, and `NotificationDecision` is written against the wire
    /// event, so handing over rows would mean a second read of what was just
    /// written and a lossy round trip through `Message` (actions survive only
    /// as JSON).
    public typealias StoredHandler = @Sendable ([NtfyEvent], UUID) async -> Void

    private let store: MessageStore
    private let batchWindow: Duration
    /// Runs inside the flush that stored the batch — see `performFlush`.
    private let onStored: StoredHandler?
    public private(set) var insertedCount = 0

    /// Serializes flushes rather than letting a concurrent one skip. `flush`
    /// is called from both of `pump`'s own child tasks for one connection —
    /// the collector on the count ceiling, the ticker on its cadence — and,
    /// because this actor is shared across every server `ConnectionCoordinator`
    /// attaches, potentially from a *different connection's* `pump` at the
    /// same moment too. Either way it suspends at `store.insert`, so without
    /// serializing them they interleave.
    ///
    /// A previous version of this guarded with a `Bool` and had a *skipping*
    /// flush return immediately, relying on the skipped batch being picked up
    /// by whichever flush wins — true for a flush with a later retry, but not
    /// for the trailing flush `pump` makes on its way out after cancellation:
    /// there is no later call, so a skip there drops whatever the buffer held
    /// the moment `pump` returns and its local `buffer` goes out of scope.
    /// This chains through a stored `Task` instead: every flush actually
    /// runs, in the order requested, however many are queued up behind the
    /// one currently draining.
    private var inFlight: Task<Void, Never>?

    public init(store: MessageStore, batchWindow: Duration = .milliseconds(250),
                onStored: StoredHandler? = nil) {
        self.store = store
        self.batchWindow = batchWindow
        self.onStored = onStored
    }

    /// Buffers events collected from one `attach` call between flushes. A
    /// dedicated actor rather than a local `var`: the collector and the
    /// periodic-flush ticker below (in `pump`) run as separate concurrent
    /// child tasks, and Swift 6 strict concurrency requires state shared
    /// between concurrent tasks to be actor-isolated.
    ///
    /// Internal rather than private so its invariants can be tested directly.
    /// They are the whole basis of the resume rule and none of them is
    /// observable from outside a flush.
    actor Buffer {
        /// Ceiling on events held across repeatedly failing inserts. A store
        /// that keeps failing must not grow this without bound; the bound has
        /// to drop *something*, and it drops the newest arrivals rather than
        /// the batch waiting to be retried, so a retry never loses ground it
        /// had already made.
        static let capacity = 10_000

        private var events: [NtfyEvent] = []
        private var lastPersistedCaughtUp: Date?
        private var dropped = false
        private var loggedOverflow = false

        /// Appends and returns the new count, so the caller can flush
        /// immediately once the count ceiling is reached without a second
        /// round trip just to read it back.
        func append(_ event: NtfyEvent) -> Int {
            guard events.count < Self.capacity else {
                noteDrop()
                return events.count
            }
            events.append(event)
            return events.count
        }

        func drain() -> [NtfyEvent] {
            defer { events.removeAll() }
            return events
        }

        /// Puts a batch whose insert failed back at the **front**, so it is
        /// retried on the next tick instead of being lost. Prepended, not
        /// appended: the collector has been appending newer events throughout
        /// the failed insert, and stream order is the entire basis for
        /// "a keepalive proves everything before it was delivered". An append
        /// would reorder the retry batch after events that follow it on the
        /// wire and make the next batch's mark a lie.
        func restore(_ batch: [NtfyEvent]) {
            events = batch + events
            guard events.count > Self.capacity else { return }
            events.removeLast(events.count - Self.capacity)
            noteDrop()
        }

        /// Whether `date` is newer than what was last persisted. The ticker
        /// calls `setCaughtUpTo` on every tick forever, including while the
        /// connection is idle; that store method is already monotonic, but
        /// it costs a `Server` fetch on every call, so skipping the ones that
        /// can't possibly advance anything keeps an idle connection from
        /// paying that cost four times a second for the app's lifetime.
        ///
        /// It also refuses outright once anything has been dropped. Past that
        /// point this buffer no longer holds every event the stream delivered,
        /// so no later keepalive can honestly claim everything before it was
        /// stored. Freezing the resume point costs a replay on the next
        /// launch; advancing it would cost the messages themselves.
        func shouldPersist(_ date: Date) -> Bool {
            guard !dropped else { return false }
            return lastPersistedCaughtUp == nil || date > lastPersistedCaughtUp!
        }

        /// Recorded only after the store confirms the write, so a failed
        /// persist attempt is retried (and re-logged) on the next tick
        /// rather than being silently treated as done.
        func markPersisted(_ date: Date) {
            lastPersistedCaughtUp = date
        }

        private func noteDrop() {
            dropped = true
            guard !loggedOverflow else { return }
            loggedOverflow = true
            // Logged once, not per event: an unreachable store would otherwise
            // emit this thousands of times a second. Never silent — the latch
            // above also stops the resume point moving, which is the visible
            // consequence a later launch would otherwise have to guess at.
            Log.store.error(
                "ingest buffer is full after repeated insert failures; dropping newly arrived events and freezing the resume point"
            )
        }
    }

    /// Starts pumping. The returned task runs until it is cancelled; the
    /// caller owns it.
    ///
    /// Cancelling it is final for this connection: `connection.events` is a
    /// single `AsyncStream` with one continuation, and once the collector's
    /// `for await` has ended the stream is not re-iterable. Resuming ingest
    /// therefore means a **new `ServerConnection`**, not a second `attach` on
    /// this one.
    ///
    /// For the same reason, do not `attach` twice to one connection: two
    /// collectors sharing one `AsyncStream` split its elements between them
    /// rather than each seeing all of them, so each would compute batch marks
    /// over half the stream — and a keepalive proving delivery would land in
    /// whichever half won the race for it.
    public func attach(_ connection: ServerConnection, serverID: UUID) -> Task<Void, Never> {
        Task { await self.pump(connection, serverID: serverID) }
    }

    private func pump(_ connection: ServerConnection, serverID: UUID) async {
        let buffer = Buffer()

        // Two concurrent loops rather than one: a collector that drains
        // `connection.events` as fast as it can (flushing immediately once
        // the count ceiling is hit), and a ticker that flushes on a fixed
        // cadence regardless of whether new events are arriving.
        //
        // One loop can't do both. Checking "has the window elapsed" only
        // when a *new* event arrives — as a single `for await` loop would —
        // means a lone event, or a trailing few under the count ceiling,
        // sits unflushed for as long as the stream stays quiet. And
        // `connection.events` has no natural end (it buffers for the
        // connection's whole lifetime; nothing ever finishes it) — a quiet
        // stream after one message is not a rare edge case, it's the normal
        // shape of a lightly-used topic.
        //
        // The ticker also persists `caughtUpTo` on every tick, not only once
        // when the loop exits: since `connection.events` only ends when this
        // task is cancelled, a stream-end-only write would never run during
        // a live connection's normal life, and a crash between launches
        // would lose all resume progress — bringing back exactly the
        // full-cache replay spec §5.2 exists to avoid.
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await event in connection.events {
                    let count = await buffer.append(event)
                    if count >= 500 {
                        await self.flush(buffer, serverID: serverID)
                    }
                }
            }
            group.addTask {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: self.batchWindow) }
                    catch { return }
                    await self.flush(buffer, serverID: serverID)
                }
            }
        }

        // The collector above only returns when this task is cancelled
        // (`connection.events` has no natural end), so this is the final
        // flush on the way out — catches whatever the last tick missed.
        await flush(buffer, serverID: serverID)
    }

    /// Queues this flush behind whatever is already draining, and waits for
    /// its own turn to finish before returning — so a caller (notably
    /// `pump`'s trailing call) that awaits `flush` has a real guarantee that
    /// draining actually happened, not just that some flush or other did.
    private func flush(_ buffer: Buffer, serverID: UUID) async {
        let previous = inFlight
        let task = Task {
            await previous?.value
            await self.performFlush(buffer, serverID: serverID)
        }
        inFlight = task
        await task.value
    }

    private func performFlush(_ buffer: Buffer, serverID: UUID) async {
        let events = await buffer.drain()
        guard !events.isEmpty else { return }

        // §5.2: only a keepalive proves the server has delivered everything up
        // to its time on every subscribed topic. `open` is never yielded, and
        // a message's own time proves nothing — ntfy replays the subscribed
        // topics one at a time rather than merging them in time order.
        //
        // Taken from this batch, so it is a claim about data this actor is
        // holding. Everything the stream delivered before this keepalive is
        // either in `events` — about to be written in one transaction — or in
        // an earlier batch, which was written before its own mark was
        // persisted. Nothing else can be below it.
        let batchMark = events
            .filter { $0.kind == .keepalive && $0.time > 0 }
            .map(\.date)
            .max()

        let result: MessageStore.InsertResult
        do {
            result = try await store.insert(events, serverID: serverID)
            insertedCount += result.inserted
        } catch {
            // Never silent, and never lossy: the batch goes back on the front
            // of the buffer for the next tick rather than being dropped. A
            // logged drop is still permanent archive loss — the connection's
            // watermarks have already moved past these events, so no
            // reconnect asks for them again. Domain and code only: an error's
            // description can embed stored or server-provided values, which
            // must not reach a log.
            await buffer.restore(events)
            let ns = error as NSError
            Log.store.error("message batch insert failed; batch held for retry: \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
            return
        }

        // Notified on stored, never on received — the same rule as the resume
        // point above, for the same reason: a notification for a message that
        // is not in the archive is one the user cannot go back and find, and a
        // failed insert must not raise a phantom alert. `result.stored` is the
        // rows this transaction actually wrote, so a duplicate a reconnect
        // replayed does not notify a second time.
        //
        // Placed here, *above* the `batchMark` guard: most batches carry no
        // keepalive and persist no resume point, and a hook below that guard
        // would never fire for them.
        //
        // Awaited rather than spawned. It runs inside the `inFlight` chain, so
        // the next flush — and, at quit, `stop()` — waits for it. That is the
        // point: a notification for the batch is raised before the app can
        // tear the store down under it, and a test can await a deterministic
        // result rather than polling a detached task. The cost is that the
        // `caughtUpTo` write below, and the next batch, wait on the handler,
        // so a handler must stay bounded (the app target's is one
        // `UNUserNotificationCenter.add` per stored message).
        if let onStored, !result.stored.isEmpty {
            await onStored(result.stored, serverID)
        }

        // Reached only past a successful insert, which is what makes the mark
        // a statement about what is durably stored. A batch with no keepalive
        // in it proved nothing and persists nothing, however many messages it
        // carried.
        guard let batchMark, await buffer.shouldPersist(batchMark) else { return }
        do {
            try await store.setCaughtUpTo(batchMark, forServer: serverID)
            await buffer.markPersisted(batchMark)
        } catch {
            // NOT error.localizedDescription: a Cocoa or SwiftData
            // error's description can embed a file's display name or a
            // stored value, either of which may be server-provided.
            // Domain and code are fixed constants.
            let ns = error as NSError
            Log.store.error("caughtUpTo persist failed: \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
        }
    }
}
