import Foundation
import Network

/// Indirection over `NWPathMonitor` so a test can drive network changes.
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
        monitor.pathUpdateHandler = { path in
            guard path.status == .satisfied else { return }
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
    }

    private let store: MessageStore
    private let keychain: KeychainStore
    private let client: any StreamClient
    private let pathMonitor: any PathMonitoring
    private let ingest: Ingest

    private var live: [UUID: Live] = [:]

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

        pathMonitor.start { [weak self] in
            await self?.reconnectAll()
        }
    }

    private func open(_ snapshot: ServerRecordSnapshot) async {
        guard live[snapshot.id] == nil else { return }

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
        live[snapshot.id] = Live(connection: connection, pump: pump)
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
    public func stop() async {
        pathMonitor.cancel()
        for entry in live.values {
            entry.pump.cancel()
            await entry.connection.stop()
        }
        for entry in live.values {
            await entry.pump.value
        }
        live.removeAll()
    }
}
