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
    /// Set for the whole of `stop()`. `open` and `sync` check it so a
    /// reconnect that lands mid-teardown cannot resurrect a connection that
    /// `stop()` has already walked past — which previously left a socket
    /// streaming with no pump and no owner, and could make `stop()` await a
    /// pump that was never cancelled and so never returns.
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

    /// Stops one connection and awaits its pump, so anything already received
    /// is durably written before the entry is dropped — the same contract
    /// `stop()` gives for all of them.
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

        let connection = ServerConnection(
            endpoint: NtfyEndpoint(baseURL: snapshot.baseURL, credential: credential),
            watermarks: snapshot.watermarks,
            caughtUpTo: snapshot.caughtUpTo,
            client: client,
            cacheWindow: snapshot.cacheWindowSeconds)

        let pump = await ingest.attach(connection, serverID: snapshot.id)
        await connection.start()
        live[snapshot.id] = Live(connection: connection, pump: pump, topics: snapshot.topics)
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
