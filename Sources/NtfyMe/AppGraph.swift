import AppKit
import Foundation
import SwiftData
import NtfyKit

/// Builds and owns the object graph: store, coordinator, notifications,
/// retention. One instance, created by the app delegate.
///
/// The path a message takes through it, end to end:
///
/// `ServerConnection` → `Ingest` → `MessageStore.insert` → the stored batch →
/// `NotificationRouter` → `NotificationDecision` → `NotificationPresenter`.
///
/// The join in the middle is the load-bearing one: notifications hang off
/// `Ingest`'s stored-batch hook, not off the connection's event stream, so
/// only a message that is actually in the archive can raise one.
@MainActor
final class AppGraph {
    private let container: ModelContainer
    let store: MessageStore
    let preferences: PreferencesStore
    /// One instance shared with `SettingsModel`, so a credential saved in
    /// Settings and one read by a connection agree on the service name.
    let keychain = KeychainStore()
    /// Also the `UNUserNotificationCenter` delegate, which is a weak
    /// reference — so this graph outliving the app delegate's `Task`s is what
    /// keeps it alive.
    let presenter = NotificationPresenter()
    private let router: NotificationRouter
    private var coordinator: ConnectionCoordinator?
    private var scheduler: RetentionScheduler?
    private var wakeObserver: NSObjectProtocol?

    /// Where the real database lives, under a directory this app owns —
    /// the same `dev.aloi.NtfyMe` directory `RetentionScheduler` keeps
    /// attachments in.
    ///
    /// Named explicitly rather than left to SwiftData's default, which is a
    /// bare `Application Support/default.store`: that path is not namespaced
    /// by bundle identifier for an unsandboxed app, so **every** SwiftData
    /// app on the machine that takes the default shares one file. Measured,
    /// not assumed — the first launch of this graph opened the machine's
    /// existing `default.store` and added this app's tables to it.
    ///
    /// **No migration is performed**, deliberately: a build predating this
    /// change wrote to that shared `default.store`, and one that follows it
    /// starts from an empty database here. No build of this app has ever been
    /// distributed, so there is nobody whose archive this can strand — but if
    /// that ever stops being true before release, this is the line that has to
    /// grow a migration rather than a comment.
    static func storeURL() throws -> URL {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appending(path: "dev.aloi.NtfyMe")
        // Created here rather than left to SwiftData: it opens a store in a
        // directory that does not exist by failing.
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        return directory.appending(path: "NtfyMe.store")
    }

    init() throws {
        // On-disk, unlike every test in this project — this is the real store.
        container = try ModelContainer(
            for: Server.self, Subscription.self, Message.self, Attachment.self,
            configurations: ModelConfiguration(url: try Self.storeURL()))
        store = MessageStore(modelContainer: container)
        preferences = PreferencesStore()
        router = NotificationRouter(store: store, preferences: preferences,
                                    presenter: presenter)
    }

    func start() async {
        let router = self.router
        let coordinator = ConnectionCoordinator(
            store: store,
            keychain: keychain,
            client: NtfyStreamClient(),
            pathMonitor: SystemPathMonitor(),
            // The hook fires inside the flush that stored the batch, with the
            // rows that flush actually wrote. See `Ingest.performFlush`.
            ingest: Ingest(store: store) { [weak self] events, serverID in
                await router.handleStored(events, serverID: serverID)
                // The badge and unread count are pull-only — there is no store
                // change stream — so without this they are only ever as fresh
                // as the refresh timer, and a message could sit in the archive
                // for up to 30 seconds before the menu bar admitted it existed.
                // `weak`: the coordinator owns the ingest that owns this
                // closure, and the graph owns the coordinator.
                await self?.notifyStoredBatch()
            })
        self.coordinator = coordinator
        await coordinator.start()

        // `[preferences]`, not a `Preferences` value loaded once here: this
        // closure is re-invoked on every prune pass, and must read whatever
        // is on disk *at that time*, not the value that happened to be
        // current at launch — see `RetentionScheduler`'s `policyProvider`
        // doc comment.
        let scheduler = RetentionScheduler(store: store, policyProvider: { [preferences] in
            preferences.load().retention
        })
        self.scheduler = scheduler
        await scheduler.start()

        // Wake from sleep: reconnect immediately rather than waiting out
        // backoff. This is the AppKit half the coordinator cannot own.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                Task { await coordinator.reconnectAll() }
            }
    }

    /// Once this returns, every batch `Ingest` had already received is durably
    /// stored and every notification for it has been handed to the system —
    /// `ConnectionCoordinator.stop()` awaits each pump's trailing flush, and
    /// the stored-batch hook runs inside that flush.
    func stop() async {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        await scheduler?.stop()
        await coordinator?.stop()
    }

    /// Not called from `start()`: spec §6 requires this to follow a short
    /// explanatory pane, never a cold prompt on first launch. The pane is UI
    /// and belongs to the next plan; this is what it will call.
    func requestNotificationAuthorization() async -> Bool {
        await presenter.requestAuthorization()
    }

    /// Where downloaded attachments live. The single definition of this path:
    /// `RetentionScheduler` prunes it and `HistoryWindowController` resolves
    /// Quick Look previews against it, and if those two ever disagreed the
    /// prune would delete files the History window still expects to find.
    ///
    /// `nil` when Application Support cannot be resolved, which disables
    /// Quick Look rather than guessing at a path.
    /// `nonisolated`: pure path computation with no shared state, called
    /// from `RetentionScheduler`, which is an actor of its own rather than
    /// main-actor bound.
    nonisolated static func attachmentsDirectory() -> URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true) else { return nil }
        return base.appending(path: "dev.aloi.NtfyMe/Attachments")
    }

    /// The menu bar popover's data source. Closures rather than a protocol
    /// because `MenuBarViewModel` deliberately does not depend on
    /// `ConnectionCoordinator` — see its `Dependencies` doc comment.
    func menuBarDependencies() -> MenuBarViewModel.Dependencies {
        MenuBarViewModel.Dependencies(
            recentMessages: { [store] in
                try await store.search(MessageQuery(limit: 50))
            },
            unreadCount: { [store] in
                try await store.unreadCount(serverID: nil, topic: nil)
            },
            connectionStatuses: { [store] in
                // Non-throwing by contract: `nil` on failure, not `[]` — an
                // empty list reads as "no servers configured", which is the
                // silent failure spec §10 forbids and is exactly what this
                // comment used to claim `[]` avoided while the code returned
                // it anyway. `MenuBarViewModel.refresh` keeps the previous
                // `serverStatuses` and surfaces `loadErrorMessage` on `nil`.
                guard let servers = try? await store.servers() else { return nil }
                let coordinator = await MainActor.run { self.coordinator }
                var statuses: [MenuBarServerStatus] = []
                for server in servers {
                    let state = await coordinator?.state(forServer: server.id) ?? .idle
                    statuses.append(MenuBarServerStatus(
                        serverID: server.id, name: server.name, state: state))
                }
                return statuses
            },
            markRead: { [store] keys, read in
                try await store.markRead(keys, read: read)
            },
            markAllRead: { [store] in
                try await store.markAllRead(serverID: nil, topic: nil)
            })
    }

    /// Per-server connection state for the History window's sidebar dots.
    /// Synchronous because `HistoryViewModel.statusProvider` is called during
    /// view rendering, so it reads the last state the coordinator published
    /// rather than awaiting a fresh one.
    func historyStatus(forServer id: UUID) -> HistoryConnectionStatus {
        Self.historyStatus(for: lastKnownStates[id])
    }

    /// The state mapping, split out so it can be tested without a graph.
    /// `nil` is `.unknown` — a server whose state has not been fetched yet is
    /// not the same as one known to be disconnected, and showing the latter
    /// would make a healthy server look broken for the first refresh interval.
    nonisolated static func historyStatus(for state: ConnectionState?) -> HistoryConnectionStatus {
        guard let state else { return .unknown }
        switch state {
        case .open: return .connected
        case .connecting, .backoff: return .connecting
        case .idle, .degraded, .unauthorized: return .disconnected
        }
    }

    /// Refreshed by the same timer that refreshes the menu bar, so the
    /// History sidebar and the status item never disagree.
    func refreshConnectionStates() async {
        guard let coordinator, let servers = try? await store.servers() else { return }
        var states: [UUID: ConnectionState] = [:]
        for server in servers {
            states[server.id] = await coordinator.state(forServer: server.id) ?? .idle
        }
        lastKnownStates = states
    }

    private var lastKnownStates: [UUID: ConnectionState] = [:]

    /// Settings owns its own model; the graph supplies the three collaborators
    /// it needs so Settings and the running connections share one store,
    /// one preferences file and one Keychain service.
    func makeSettingsModel() -> SettingsModel {
        SettingsModel(store: store, preferences: preferences, keychain: keychain)
    }


    /// Called after a batch is stored and its notifications raised, so the
    /// menu bar reflects a new message immediately rather than at the next
    /// timer tick. Set by `AppDelegate`, which owns the status item.
    var onStoredBatch: () -> Void = {}

    private func notifyStoredBatch() {
        onStoredBatch()
    }

}
