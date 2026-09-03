import Foundation
import Network
import Synchronization

/// Indirection over `NWPathMonitor` so a test can drive network changes.
///
/// **`onSatisfied` reports a transition, not a level.** An implementation must
/// call it when the path *becomes* satisfied, and must not call it for the
/// state that was already true when `start` was called. `NWPathMonitor` does
/// report current state immediately, so `SystemPathMonitor` absorbs that first
/// delivery; a conforming fake fires only when a test asks it to, and every
/// such call is therefore a real transition.
///
/// The distinction is load-bearing. Treating the initial level as a transition
/// made every launch call `reconnectAll()` immediately, tearing down the
/// connections `start()` had just opened and re-requesting each replay window
/// a second time. Putting the rule here rather than in the coordinator keeps
/// the coordinator honest about what it is reacting to, and keeps a fake's
/// single trigger meaning exactly one transition.
public protocol PathMonitoring: Sendable {
    func start(onSatisfied: @Sendable @escaping () async -> Void)
    func cancel()
}

/// Fires whenever the system path becomes satisfied — the signal that a
/// reconnect should happen immediately rather than waiting out backoff.
public struct SystemPathMonitor: PathMonitoring {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "dev.aloi.NtfyMe.path")

    public init() {}

    public func start(onSatisfied: @Sendable @escaping () async -> Void) {
        // `NWPathMonitor` delivers the current path as soon as it starts, so
        // the first update describes the state that already held rather than a
        // change to it. Absorbed here to satisfy `PathMonitoring`'s contract.
        // All handler calls arrive serially on `queue`, so this needs no
        // further synchronisation.
        let hasReportedInitialPath = Mutex(false)
        monitor.pathUpdateHandler = { path in
            let isFirst = hasReportedInitialPath.withLock { reported -> Bool in
                defer { reported = true }
                return !reported
            }
            guard !isFirst, path.status == .satisfied else { return }
            Task { await onSatisfied() }
        }
        monitor.start(queue: queue)
    }

    public func cancel() { monitor.cancel() }
}

/// Owns one `ServerConnection` per configured server.
///
/// This is the first production construction site for `ServerConnection`, and
/// it is what closes §5.2's loop: each connection is seeded with the watermarks
/// and `caughtUpTo` the store persisted, so a restart resumes rather than
/// replaying every quiet topic's cache.
///
/// Sleep and wake are NOT handled here — `NSWorkspace` is AppKit and `NtfyKit`
/// imports no UI framework. The app target observes those and calls
/// `reconnectAll()`.
public actor ConnectionCoordinator {
    private struct Live {
        let connection: ServerConnection
        let pump: Task<Void, Never>
        /// The topic set this connection was opened with. `sync` compares
        /// against the stored set to decide whether a restart is needed —
        /// a subscription is fixed at connect time, so adding a topic means
        /// reconnecting, not mutating a live stream.
        let topics: [String]
    }

    private let store: MessageStore
    private let keychain: KeychainStore
    private let client: any StreamClient
    private let pathMonitor: any PathMonitoring
    private let ingest: Ingest

    private var live: [UUID: Live] = [:]
    /// Every in-flight `Backfill.run` this coordinator has started, held so
    /// `stop()` can cancel and await them — not fired detached and
    /// forgotten. `stop()`'s whole contract is that once it returns, this
    /// coordinator has stopped cleanly and nothing is still writing; a
    /// forgotten backfill task still mid-`store.insert` when the app quits
    /// or the store tears down right after `stop()` returns would race
    /// exactly that, the same class of bug the review found in
    /// `pathMonitor.cancel()` not cancelling an in-flight reconnect `Task`.
    /// An array, not a literal `Set` — order doesn't matter and `Task`'s
    /// `Hashable` conformance isn't needed, but the two-pass cancel-then-
    /// await shape mirrors `stop()`'s own `entries` snapshot below.
    private var backfillTasks: [Task<Void, Never>] = []
    /// Set for the whole of `stop()`. `open` and `sync` check it so a
    /// reconnect that lands mid-teardown cannot resurrect a connection that
    /// `stop()` has already walked past — which previously left a socket
    /// streaming with no pump and no owner, and could make `stop()` await a
    /// pump that was never cancelled and so never returns. `open` also
    /// checks it a second time, just before starting a backfill, to close
    /// the same reentrancy window for backfill tasks: `open`'s own several
    /// `await`s between its first check and reaching that point give
    /// `stop()` room to land in between.
    private var isStopping = false

    public init(store: MessageStore, keychain: KeychainStore,
                client: any StreamClient, pathMonitor: any PathMonitoring,
                ingest: Ingest) {
        self.store = store
        self.keychain = keychain
        self.client = client
        self.pathMonitor = pathMonitor
        self.ingest = ingest
    }

    public var connectionCount: Int { live.count }

    public func state(forServer id: UUID) async -> ConnectionState? {
        guard let entry = live[id] else { return nil }
        return await entry.connection.state
    }

    public func start() async {
        // Started before the store is read, not after. A transient failure
        // loading servers used to return early and leave the monitor never
        // started, so the process stayed deaf to network recovery for its
        // entire lifetime with only a log line to say so (spec §10).
        pathMonitor.start { [weak self] in
            await self?.reconnectAll()
        }

        let snapshots: [ServerRecordSnapshot]
        do {
            snapshots = try await store.servers()
        } catch {
            let ns = error as NSError
            Log.connection.error("could not load servers: \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
            return
        }

        for snapshot in snapshots where !snapshot.topics.isEmpty {
            await open(snapshot)
        }
    }

    /// Brings live connections into line with what the store now holds:
    /// opens servers that appeared, stops ones that were removed or had their
    /// last topic removed, and restarts any whose topic set changed.
    ///
    /// This exists because a subscription is fixed when the stream is opened.
    /// Without it, a server or topic added through the app's own Settings
    /// never connected until the next launch — the entire first-run path
    /// produced no messages, no error, and no hint that a relaunch was
    /// needed. Call it after any change to the stored server list.
    public func sync() async {
        guard !isStopping else { return }

        let snapshots: [ServerRecordSnapshot]
        do {
            snapshots = try await store.servers()
        } catch {
            let ns = error as NSError
            Log.connection.error("sync could not load servers: \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
            return
        }

        let wanted = Dictionary(uniqueKeysWithValues:
            snapshots.filter { !$0.topics.isEmpty }.map { ($0.id, $0) })

        // Gone, or down to no topics: stop and forget.
        for id in live.keys where wanted[id] == nil {
            await close(id)
        }

        for (id, snapshot) in wanted {
            if let entry = live[id] {
                // A live connection's subscription cannot be edited in place.
                if entry.topics != snapshot.topics {
                    await close(id)
                    await open(snapshot)
                }
            } else {
                await open(snapshot)
            }
        }
    }

    /// Drops and reopens one server's connection — for a credential change,
    /// which `sync` cannot detect because credentials live in the Keychain
    /// rather than in the stored record it diffs.
    public func restart(serverID: UUID) async {
        guard !isStopping else { return }
        await close(serverID)
        guard let snapshot = try? await store.servers().first(where: { $0.id == serverID }),
              !snapshot.topics.isEmpty else { return }
        await open(snapshot)
    }

    /// Stops one server's connection and awaits its pump, so anything already
    /// received is durably written before the entry is dropped — the same
    /// contract `stop()` gives for all of them. Returns once nothing is
    /// streaming for that server.
    ///
    /// Public because removing a server has to stop its connection *before*
    /// the store purge, not after. `MessageStore.removeServer` deletes the
    /// server row, its subscriptions and all its messages in one atomic call,
    /// so there is no way to decompose it caller-side; the ordering can only
    /// come from here. Purging while the connection is live leaves its pump
    /// inserting rows keyed to a server row that no longer exists — orphans
    /// that are visible in History and the popover, still raise
    /// notifications, and can never be removed again, because `removeServer`
    /// early-returns on an unknown id.
    public func close(serverID: UUID) async {
        await close(serverID)
    }

    private func close(_ id: UUID) async {
        guard let entry = live.removeValue(forKey: id) else { return }
        entry.pump.cancel()
        await entry.connection.stop()
        await entry.pump.value
    }

    private func open(_ snapshot: ServerRecordSnapshot) async {
        guard !isStopping, live[snapshot.id] == nil else { return }

        let credential: AuthCredential
        do {
            credential = try keychain.load(forServer: snapshot.id)
        } catch {
            // A credential that cannot be read is not a reason to skip the
            // server: an unauthenticated attempt gets a 401 the user can see,
            // which is more useful than silence.
            Log.connection.error("keychain read failed for server \(snapshot.id.uuidString, privacy: .public)")
            credential = .unauthenticated
        }

        let endpoint = NtfyEndpoint(baseURL: snapshot.baseURL, credential: credential)
        let connection = ServerConnection(
            endpoint: endpoint,
            watermarks: snapshot.watermarks,
            caughtUpTo: snapshot.caughtUpTo,
            client: client,
            cacheWindow: snapshot.cacheWindowSeconds)

        let pump = await ingest.attach(connection, serverID: snapshot.id)
        await connection.start()
        live[snapshot.id] = Live(connection: connection, pump: pump, topics: snapshot.topics)

        backfillUnsyncedTopics(in: snapshot, endpoint: endpoint)
    }

    /// Backfills every topic in `snapshot` the shared stream will never
    /// retroactively fill in on its own — `TopicWatermark.lastMessageTime
    /// == nil`, spec §5, is exactly the condition `Backfill`'s own doc
    /// comment names: a nil-watermark topic is deliberately excluded from
    /// `WatermarkResolver`'s shared resume point, precisely so it cannot
    /// drag every other topic's replay back to the epoch — which also
    /// means nothing else ever fills in its history unless this does.
    ///
    /// Reuses `endpoint` (and its already-loaded credential) rather than
    /// reloading the Keychain a second time — `open` just built it for
    /// exactly this server. Runs after `connection.start()`, not before:
    /// the live stream and the one-shot backfill poll race deliberately —
    /// `store.insert`'s dedup (by `uniqueKey`) makes that race safe, and
    /// waiting for backfill to finish first would delay every other
    /// topic's connection on this server for however long the poll takes
    /// (up to `Backfill`'s 30s timeout).
    ///
    /// A topic backfilled to genuinely zero messages stays nil-watermarked
    /// — `advanceWatermarks` has nothing to advance from — so a later
    /// `open` for the same server (another topic changing, a credential
    /// restart) backfills it again. Accepted rather than tracked and
    /// suppressed: a topic with real server-cached history only ever
    /// backfills once, and one more bounded, cheap poll for a topic that
    /// turns out to be genuinely empty is not worth the bookkeeping to
    /// avoid.
    private func backfillUnsyncedTopics(in snapshot: ServerRecordSnapshot, endpoint: NtfyEndpoint) {
        // Re-checked here, not just at `open`'s own entry: `open` suspends
        // multiple times (the Keychain load, `ingest.attach`,
        // `connection.start()`) before reaching this point, and `stop()`
        // could land in any of those gaps. Nothing between this check and
        // `backfillTasks.append` below awaits, so — like every other
        // `isStopping` check in this actor — it is atomic with respect to
        // a concurrent `stop()`.
        guard !isStopping else { return }
        let unsyncedTopics = snapshot.watermarks.filter { $0.lastMessageTime == nil }.map(\.topic)
        guard !unsyncedTopics.isEmpty else { return }

        // `ingest.onStored` — the same hook a live-stream flush calls — so a
        // backfilled row reaches the app layer's attachment fetcher and
        // badge refresh too, not just the store. See `Ingest.StoredSource`.
        let backfill = Backfill(endpoint: endpoint, client: client, store: store,
                                onStored: ingest.onStored)
        let serverID = snapshot.id
        for topic in unsyncedTopics {
            let task = Task {
                do {
                    try await backfill.run(topic: topic, serverID: serverID)
                } catch {
                    // Domain/code, not `error.localizedDescription` or the
                    // topic name itself — both are, or can embed, content
                    // that ultimately traces back to the server (`Log.swift`'s
                    // doc comment), matching every other `catch` in this file.
                    let ns = error as NSError
                    Log.connection.error("backfill failed: \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
                }
            }
            backfillTasks.append(task)
        }
    }

    /// Called on wake from sleep and when the network path becomes satisfied.
    /// Bypasses any pending backoff.
    public func reconnectAll() async {
        for entry in live.values {
            await entry.connection.reconnectNow()
        }
    }

    /// `stop()`'s contract is that once it returns, this coordinator has
    /// stopped cleanly — including that everything Ingest had already
    /// received is durably persisted, not merely "will be, eventually." A
    /// caller that quits or tears down the store right after `await
    /// coordinator.stop()` must not lose a batch a pump was still holding.
    ///
    /// Cancelling is not enough on its own: `entry.pump.cancel()` returns
    /// immediately, but `Ingest.pump`'s trailing flush — the durable write
    /// of the last accumulated batch and its `caughtUpTo` — only runs after
    /// cancellation is *observed* inside that task, which happens on its own
    /// schedule. So every pump is awaited to completion before this returns.
    ///
    /// Two passes, but *not* "cancel every pump, then stop every connection
    /// and await every pump" — `entry.connection.stop()` is paired with
    /// `entry.pump.cancel()` in the same, first pass, one entry at a time.
    /// With multiple live entries, splitting cancel-every-pump from
    /// stop-every-connection into separate passes leaves every
    /// not-yet-reached connection still fully running — still pulling lines
    /// off the wire and yielding them onto `connection.events` — while its
    /// own pump's collector has *already* exited (cancelled in the first
    /// pass). Nothing is left to drain what it yields during that window, so
    /// it is lost the same way an un-drained trailing buffer is, and the
    /// window is not narrow: it lasts as long as *every earlier* entry's own
    /// pump takes to finish draining, which can be a real batch's worth of
    /// `store.insert` calls. Stopping each connection in the same breath as
    /// cancelling its pump closes that window — nothing is still producing
    /// once this first pass finishes an entry. The second pass then only
    /// awaits already-cancelled, already-stopped pumps to finish draining
    /// whatever they already held, which is where the entries genuinely can,
    /// and should, drain concurrently in the background rather than being
    /// serialized behind one another.
    ///
    /// **This pairing fixes no observed defect, and no test pins it.**
    /// Abandoning a connection's not-yet-processed backlog on `stop()` is
    /// legitimate — the server resends it on the next reconnect, keyed off
    /// the watermark — which is exactly why no test can tell "the window
    /// above dropped an already-yielded event" apart from "stop() correctly
    /// abandoned an event nobody had gotten to yet": both look identical
    /// from outside, a lower final message count than some larger number
    /// that was never promised. This ordering is kept because it is a
    /// clearer formulation of the same two-pass structure, not because it
    /// is known to fix anything: closing the window between cancelling a
    /// pump and stopping its connection is strictly harder to get wrong
    /// than leaving it open on purpose.
    public func stop() async {
        isStopping = true
        pathMonitor.cancel()

        // Same cancel-then-await shape as the pumps below, and the same
        // reason: `Backfill.run` honors external cancellation by design
        // (throwing `CancellationError` and inserting nothing — see its
        // own doc comment), but `cancel()` only REQUESTS that; awaiting
        // `.value` afterward is what actually guarantees none of them is
        // still mid-`store.insert` by the time `stop()` returns. Snapshotted
        // and cleared before either pass, mirroring `entries` below, so a
        // backfill `open` starts after this point (closed by `isStopping`,
        // checked again just before `backfillTasks.append`) is never
        // half-included in one pass but not the other.
        let pendingBackfills = backfillTasks
        backfillTasks.removeAll()
        for task in pendingBackfills {
            task.cancel()
        }
        for task in pendingBackfills {
            await task.value
        }

        // Snapshotted before the first pass. Each `await` below suspends this
        // actor, and an entry added during one of those suspensions would be
        // missed by the first pass but reached by the second — leaving `stop()`
        // awaiting a pump that was never cancelled, which only returns on
        // cancellation. That is an app that cannot quit. `isStopping` prevents
        // the insertion; iterating the snapshot means the two passes cover
        // exactly the same entries even if it did not.
        let entries = Array(live.values)
        for entry in entries {
            entry.pump.cancel()
            await entry.connection.stop()
        }
        for entry in entries {
            await entry.pump.value
        }
        live.removeAll()
    }
}
