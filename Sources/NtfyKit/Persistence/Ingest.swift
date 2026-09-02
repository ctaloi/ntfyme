import Foundation

/// Drains a connection's event stream into the store.
///
/// Events are batched over a short window rather than written one at a time:
/// a reconnect replay can deliver thousands of lines at once, and one
/// transaction per message would be pathological.
public actor Ingest {
    private let store: MessageStore
    private let batchWindow: Duration
    public private(set) var insertedCount = 0

    public init(store: MessageStore, batchWindow: Duration = .milliseconds(250)) {
        self.store = store
        self.batchWindow = batchWindow
    }

    /// Buffers events collected from one `attach` call between flushes. A
    /// dedicated actor rather than a local `var`: the collector and the
    /// periodic-flush ticker below (in `pump`) run as separate concurrent
    /// child tasks, and Swift 6 strict concurrency requires state shared
    /// between concurrent tasks to be actor-isolated.
    private actor Buffer {
        private var events: [NtfyEvent] = []
        private var lastPersistedCaughtUp: Date?

        /// Appends and returns the new count, so the caller can flush
        /// immediately once the count ceiling is reached without a second
        /// round trip just to read it back.
        func append(_ event: NtfyEvent) -> Int {
            events.append(event)
            return events.count
        }

        func drain() -> [NtfyEvent] {
            defer { events.removeAll() }
            return events
        }

        /// Whether `date` is newer than what was last persisted. The ticker
        /// calls `setCaughtUpTo` on every tick forever, including while the
        /// connection is idle; that store method is already monotonic, but
        /// it costs a `Server` fetch on every call, so skipping the ones that
        /// can't possibly advance anything keeps an idle connection from
        /// paying that cost four times a second for the app's lifetime.
        func shouldPersist(_ date: Date) -> Bool {
            lastPersistedCaughtUp == nil || date > lastPersistedCaughtUp!
        }

        /// Recorded only after the store confirms the write, so a failed
        /// persist attempt is retried (and re-logged) on the next tick
        /// rather than being silently treated as done.
        func markPersisted(_ date: Date) {
            lastPersistedCaughtUp = date
        }
    }

    /// Starts pumping. The returned task runs until it is cancelled; the
    /// caller owns it.
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
                        await self.flush(buffer, connection: connection, serverID: serverID)
                    }
                }
            }
            group.addTask {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: self.batchWindow) }
                    catch { return }
                    await self.flush(buffer, connection: connection, serverID: serverID)
                }
            }
        }

        // The collector above only returns when this task is cancelled
        // (`connection.events` has no natural end), so this is the final
        // flush on the way out — catches whatever the last tick missed.
        await flush(buffer, connection: connection, serverID: serverID)
    }

    private func flush(_ buffer: Buffer, connection: ServerConnection, serverID: UUID) async {
        let events = await buffer.drain()
        if !events.isEmpty {
            do {
                let result = try await store.insert(events, serverID: serverID)
                insertedCount += result.inserted
            } catch {
                // Never silent: a failed write means messages were delivered
                // but lost from the archive. Domain and code only — an
                // error's description can embed stored or server-provided
                // values, which must not reach a log.
                let ns = error as NSError
                Log.store.error("message batch insert failed: \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
            }
        }

        // The connection derived this from every line it saw, including
        // keepalives that produce no rows. Persisting it on every flush —
        // not only when the loop ends — is what makes a restart resume from
        // §5.2's point rather than the oldest message, even across a crash.
        // Guarded by `shouldPersist` so an idle connection, ticking forever,
        // doesn't re-fetch and re-write a value that hasn't advanced.
        if let caughtUp = await connection.caughtUpTo, await buffer.shouldPersist(caughtUp) {
            do {
                try await store.setCaughtUpTo(caughtUp, forServer: serverID)
                await buffer.markPersisted(caughtUp)
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
}
