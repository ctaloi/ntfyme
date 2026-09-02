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
    private var onboardingWindow: NSWindow?
    private let activationPolicy = ActivationPolicyController()
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
        // Menu-bar-first: no Dock icon until a window opens (spec §7). The
        // controller takes over from here — every later change goes through it
        // so that two windows cannot fight over one app-wide setting.
        NSApp.setActivationPolicy(.accessory)
        activationPolicy.start()

        do {
            let graph = try AppGraph()
            self.graph = graph
            UNUserNotificationCenter.current().delegate = graph.presenter
            settingsModel = graph.makeSettingsModel()

            let history = HistoryWindowController(
                store: graph.store,
                attachmentsDirectory: AppGraph.attachmentsDirectory())
            history.setStatusProvider { [weak graph] id in
                graph?.historyStatus(forServer: id) ?? .unknown
            }
            self.history = history

            let menuBar = MenuBarController(dependencies: graph.menuBarDependencies())
            menuBar.onOpenHistory = { [weak self] in self?.openHistory() }
            menuBar.onOpenSettings = { [weak self] in self?.openSettings() }
            self.menuBar = menuBar

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

    private func openHistory() {
        history?.show()
        // Directly rather than waiting for the window notification, so the
        // Dock icon appears as the window does rather than a beat later.
        activationPolicy.update()
    }

    /// Opens the standard SwiftUI `Settings` scene. There is no AppKit-facing
    /// API for this, so it goes through the action the Settings scene installs
    /// on the responder chain. The selector was renamed in macOS 14, so both
    /// are attempted rather than assuming the newer one is present.
    private func openSettings() {
        let selectors = [Selector(("showSettingsWindow:")), Selector(("showPreferencesWindow:"))]
        for selector in selectors where NSApp.sendAction(selector, to: nil, from: nil) {
            activationPolicy.update()
            return
        }
        Log.app.error("could not open the Settings scene: no responder handled either selector")
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
