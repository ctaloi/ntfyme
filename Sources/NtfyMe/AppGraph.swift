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
    private let store: MessageStore
    private let preferences: PreferencesStore
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
        let prefs = preferences.load()

        let router = self.router
        let coordinator = ConnectionCoordinator(
            store: store,
            keychain: KeychainStore(),
            client: NtfyStreamClient(),
            pathMonitor: SystemPathMonitor(),
            // The hook fires inside the flush that stored the batch, with the
            // rows that flush actually wrote. See `Ingest.performFlush`.
            ingest: Ingest(store: store) { events, serverID in
                await router.handleStored(events, serverID: serverID)
            })
        self.coordinator = coordinator
        await coordinator.start()

        let scheduler = RetentionScheduler(store: store, policy: prefs.retention)
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
}
