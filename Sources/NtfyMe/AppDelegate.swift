import AppKit
import SwiftUI
import NtfyKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    /// Held for the app's lifetime: it owns the store, the connections and the
    /// presenter, and `UNUserNotificationCenter.delegate` is a weak reference.
    ///
    /// `nil` only if the on-disk store could not be opened — see
    /// `applicationDidFinishLaunching`.
    private var graph: AppGraph?
    private var menuBar: MenuBarController?
    private var history: HistoryWindowController?
    private var settings: SettingsWindowController?
    private var compose: ComposeWindowController?
    private var onboardingWindow: NSWindow?
    private let activationPolicy = ActivationPolicyController()
    /// Sparkle auto-update wrapper (see `Updater`). Started at launch when
    /// the app is configured for updates; inert otherwise.
    private let updater = Updater()
    /// The one fan-out from "the store changed" to every surface displaying
    /// it. Owned here because this is where those surfaces are created; see
    /// `StoreChangeBroadcast` for why the point-to-point closures it replaces
    /// kept producing the same bug.
    private let storeChanges = StoreChangeBroadcast()
    private var refreshTimer: Timer?

    /// Published so the SwiftUI `Settings` scene can build its tabs once the
    /// graph exists. The scene is constructed before
    /// `applicationDidFinishLaunching` runs, so it has to observe this rather
    /// than read it once.
    @Published private(set) var settingsModel: SettingsModel?

    /// Guards against replying to `applicationShouldTerminate` twice, since
    /// both the shutdown and its watchdog below can get there.
    private var hasRepliedToTerminate = false

    /// How long a quit waits for connections to stop and the last batch to be
    /// written before giving up on it. Long enough for a flush in progress,
    /// short enough that a wedged one cannot make the app unquittable.
    private static let shutdownTimeout: TimeInterval = 5

    /// How often the status item's badge and the History sidebar's dots are
    /// refreshed. There is no store change stream, so this is a poll — see
    /// `MenuBarController`'s doc comment. Cheap: two indexed counts.
    private static let refreshInterval: TimeInterval = 30

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A real Mac app: Dock icon, app menu, and a main window at launch.
        // This used to start `.accessory` with no Dock icon, which is what
        // made the whole thing feel like a utility with windows bolted on
        // rather than an application — the components were always native, the
        // shape was not.
        //
        // `ActivationPolicyController` still owns the policy from here, and
        // still flips to `.accessory` when the last window closes. That is now
        // the *demotion* path rather than the resting state: the app keeps
        // running and receiving messages in the menu bar, which is what a
        // notification client has to do to be worth anything.
        NSApp.setActivationPolicy(.regular)
        activationPolicy.start()
        updater.start()

        do {
            let graph = try AppGraph()
            self.graph = graph
            UNUserNotificationCenter.current().delegate = graph.presenter

            // Every write Settings makes reaches the broadcast, which the
            // observers registered below fan out to. Ordering no longer
            // matters here — this used to have to be built after the History
            // window so it could be handed one — because a surface registers
            // itself whenever it happens to exist.
            let settingsModel = graph.makeSettingsModel(
                onStoreChanged: { [storeChanges] in await storeChanges.post() })
            self.settingsModel = settingsModel
            settings = SettingsWindowController(model: settingsModel)
            compose = ComposeWindowController(model: graph.makeComposeModel())

            // Spec §6 activation. The presenter resolves what the tap meant
            // from the notification's own payload; this decides what to do
            // with the answer, because windows and URL opening live here.
            graph.presenter.onActivation = { [weak self] activation in
                switch activation {
                case .openURL(let url):
                    NSWorkspace.shared.open(url)
                case .openHistory(let messageKey):
                    // Spec §6: a notification without a `click` URL opens
                    // History *at that message*. The banner may be clicked
                    // long after the launch that created it, so the message
                    // may well have been pruned by then — `reveal` falls back
                    // to the containing topic with an explanation rather than
                    // doing nothing, which is the normal outcome here rather
                    // than an edge case.
                    self?.openHistory(revealing: messageKey)
                case .perform(let action):
                    Task { await NotificationActionHandler.perform(action) }
                }
            }

            let history = HistoryWindowController(
                store: graph.store,
                attachmentsDirectory: AppGraph.attachmentsDirectory())
            history.setStatusProvider { [weak graph] id in
                graph?.historyStatus(forServer: id) ?? .unknown
            }
            // The toolbar's paperplane and ⇧⌘N reach the same window through
            // the same method — there is deliberately one path to a Compose
            // window, as there is to a Settings one. The toolbar's + is the
            // one door to "add a subscription": Settings, already pointed
            // at the tab where topics live.
            history.onNewMessage = { [weak self] seed in self?.openCompose(seed: seed) }
            history.onAddSubscription = { [weak self] in self?.openAddSubscription() }
            self.history = history

            let menuBar = MenuBarController(dependencies: graph.menuBarDependencies())
            menuBar.onOpenHistory = { [weak self] in self?.openHistory() }
            menuBar.onOpenSettings = { [weak self] in self?.openSettings() }
            menuBar.onCompose = { [weak self] in self?.openCompose() }
            menuBar.onOpenMessage = { [weak self] key in self?.openHistory(revealing: key) }
            menuBar.onRetryConnection = { [weak graph, weak menuBar] in
                Task {
                    await graph?.reconnectAll()
                    // Refresh straight after, so the status row reflects the
                    // attempt rather than leaving the user watching a stale
                    // state and wondering whether Retry did anything.
                    await graph?.refreshConnectionStates()
                    await menuBar?.refreshNow()
                }
            }
            self.menuBar = menuBar

            // The two surfaces that display the store. Both capture weakly:
            // the broadcast never unregisters an observer (see `observe`), so
            // this is what makes one whose surface is gone a no-op instead of
            // something that keeps it alive.
            //
            // The sidebar, and now also the open list — but the list only
            // ever by *inserting new arrivals* (`storeDidChange`), never a
            // full reload: a `refreshMessages()` under the user resets
            // pagination to the first page and scrolls them back to the top,
            // which is a worse trade than any staleness. Arriving messages
            // joining the top of "All Messages" while the window sits open
            // is the behavior a live archive owes its reader; everything else
            // about the list (scope, filters, page 2+) still reloads on the
            // user's own actions. Its remaining gap (a read/delete made in
            // another surface not re-querying an open list) is tracked in
            // `docs/superpowers/followups.md`.
            storeChanges.observe { [weak history] in await history?.storeDidChange() }
            storeChanges.observe { [weak menuBar] in await menuBar?.refreshNow() }

            // A stored batch is a store change like any other, so it goes
            // through the same fan-out rather than its own closure to the
            // menu bar — which is what it was before, and why a new message
            // updated the status item but not the sidebar's unread badges.
            graph.onStoredBatch = { [storeChanges] in
                Task { await storeChanges.post() }
            }

            // The main window *is* the app now, so it opens at launch rather
            // than waiting to be summoned from a menu.
            openHistory()

            Task {
                await graph.start()
                await graph.refreshConnectionStates()
                await menuBar.refreshNow()
                await self.presentOnboardingIfNeeded()
            }
            startRefreshTimer()
        } catch {
            // The store is the graph's foundation — without it there is
            // nothing to connect to a server *for*. A menu bar with a Quit
            // item still comes up rather than the app dying silently at
            // launch, which at least leaves something to see and something to
            // quit.
            //
            // Domain and code only, never `localizedDescription`: a Core
            // Data store-open failure embeds the store file's path.
            let ns = error as NSError
            Log.app.error("could not open the message store; running without connections: \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
            presentStoreFailureMenuBar()
        }
    }

    // MARK: - Windows

    /// Opens History and reveals one message — the popover's row tap and a
    /// notification's activation both land here.
    private func openHistory(revealing messageKey: String) {
        guard let history else { return }
        Task { await history.show(revealing: messageKey) }
        activationPolicy.update()
    }

    private func openHistory() {
        history?.show()
        // Directly rather than waiting for the window notification, so the
        // Dock icon appears as the window does rather than a beat later.
        activationPolicy.update()
    }

    /// Opens Settings in a window this app owns — see
    /// `SettingsWindowController` for why the standard `Settings` scene could
    /// not be used from a menu-bar accessory. Not `private`: `NtfyMeApp`'s
    /// `CommandGroup(replacing: .appSettings)` calls this directly for ⌘, —
    /// the scene's own auto-wired `showSettingsWindow:` has the same
    /// no-key-window problem this method exists to route around, so ⌘, has
    /// to reach this exact method rather than the scene, and there is
    /// deliberately only this one path to a Settings window.
    func openSettings() {
        settings?.show()
        activationPolicy.update()
    }

    /// Opens the Compose window. Not `private`: `NtfyMeApp`'s
    /// `CommandGroup(replacing: .newItem)` calls this for ⌘N, the same route
    /// `openSettings()` takes for ⌘, and for the same reason — a command
    /// that has to reach a window this app hosts itself rather than a
    /// SwiftUI scene. A seed (see `ComposeSeed`) is the "send to this topic"
    /// path from History's toolbar or a row's context menu.
    /// Check for Updates (⌘U). A no-op when the app was built without
    /// updater configuration — dev builds — rather than an error dialog
    /// about a missing appcast.
    func checkForUpdates() {
        updater.checkForUpdates()
    }

    func openCompose(seed: ComposeSeed? = nil) {
        compose?.show(seed: seed)
        activationPolicy.update()
    }

    /// Opens Settings already on the Servers tab — the History toolbar's
    /// Add Subscription button, and ⇧⌘N. Not a new path to Settings: the
    /// same `openSettings()` everything else uses, with the tab chosen
    /// first, because "add a subscription" is a destination, not a tab the
    /// user should have to find.
    func openAddSubscription() {
        settingsModel?.selectedTab = .servers
        openSettings()
    }

    /// The notification-permission pane (spec §6): a short explanation before
    /// the system prompt, never a cold prompt at first launch.
    ///
    /// Gated on the system's own authorization status rather than a flag this
    /// app persists — once the user has answered, `.notDetermined` is no
    /// longer true and the pane cannot come back, which is exactly the
    /// "show once" behaviour without a preference to keep in sync.
    private func presentOnboardingIfNeeded() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "Notifications"
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: OnboardingView(
            onRequestAuthorization: { [weak self] in
                await self?.graph?.requestNotificationAuthorization() ?? false
            },
            onFinish: { [weak self] in self?.dismissOnboarding() },
            onSkip: { [weak self] in self?.dismissOnboarding() }))
        onboardingWindow = window
        window.makeKeyAndOrderFront(nil)
        activationPolicy.update()
    }

    private func dismissOnboarding() {
        onboardingWindow?.close()
        onboardingWindow = nil
        activationPolicy.update()
    }

    /// A menu bar with nothing behind it, for the store-open failure path.
    /// Built here rather than reusing `MenuBarController`, which requires the
    /// store the app just failed to open.
    private func presentStoreFailureMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let image = NSImage(systemSymbolName: "bell.slash", accessibilityDescription: "NtfyMe")
        image?.isTemplate = true
        item.button?.image = image
        let menu = NSMenu()
        menu.addItem(withTitle: "NtfyMe couldn't open its message archive", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit NtfyMe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        storeFailureItem = item
    }

    private var storeFailureItem: NSStatusItem?

    private func startRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval,
                                            repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.graph?.refreshConnectionStates()
                await self.menuBar?.refreshNow()
            }
        }
    }

    // MARK: - Shutdown

    /// Quitting waits for the graph to stop, so the last batch a pump is
    /// holding is written and its notification raised before the process
    /// goes away (`AppGraph.stop()`'s contract).
    ///
    /// `.terminateLater` rather than `applicationWillTerminate`: that callback
    /// is synchronous and the process exits the moment it returns, so a
    /// `Task` started there would be killed mid-flush — the exact loss
    /// `ConnectionCoordinator.stop()` exists to prevent.
    /// Closing the last window leaves the app running in the menu bar rather
    /// than quitting. For a notification client, quitting on window-close
    /// would silently stop the one thing it exists to do; the menu bar icon
    /// is what tells the user it is still working.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Clicking the Dock icon, or reopening from the Finder, brings the main
    /// window back — the standard behaviour for an app that outlives its
    /// windows.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openHistory() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        refreshTimer?.invalidate()
        refreshTimer = nil
        activationPolicy.stop()

        guard let graph else { return .terminateNow }

        Task {
            await graph.stop()
            replyToTerminate()
        }
        // Bounded, so a wedged flush cannot make the app unquittable. On the
        // main queue rather than inside the `Task` above, so it fires whether
        // or not that task is making progress.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.shutdownTimeout) { [weak self] in
            guard let self, !self.hasRepliedToTerminate else { return }
            Log.app.error("shutdown timed out; quitting without a clean stop")
            self.replyToTerminate()
        }
        return .terminateLater
    }

    private func replyToTerminate() {
        guard !hasRepliedToTerminate else { return }
        hasRepliedToTerminate = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }
}
