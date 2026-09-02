import AppKit
import NtfyKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    /// Held for the app's lifetime: it owns the store, the connections and the
    /// presenter, and `UNUserNotificationCenter.delegate` is a weak reference.
    ///
    /// `nil` only if the on-disk store could not be opened — see
    /// `applicationDidFinishLaunching`.
    private var graph: AppGraph?
    /// Guards against replying to `applicationShouldTerminate` twice, since
    /// both the shutdown and its watchdog below can get there.
    private var hasRepliedToTerminate = false

    /// How long a quit waits for connections to stop and the last batch to be
    /// written before giving up on it. Long enough for a flush in progress,
    /// short enough that a wedged one cannot make the app unquittable.
    private static let shutdownTimeout: TimeInterval = 5

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-first: no Dock icon until a window opens (spec §7).
        NSApp.setActivationPolicy(.accessory)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let image = NSImage(systemSymbolName: "bell", accessibilityDescription: "NtfyMe")
        image?.isTemplate = true
        item.button?.image = image

        let menu = NSMenu()
        menu.addItem(
            withTitle: "Quit NtfyMe",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        item.menu = menu

        statusItem = item

        do {
            let graph = try AppGraph()
            self.graph = graph
            UNUserNotificationCenter.current().delegate = graph.presenter
            // Authorization is NOT requested here: spec §6 wants it after a
            // short explanatory pane, never as a cold prompt on first launch.
            // The pane is UI and belongs to the next plan.
            Task { await graph.start() }
        } catch {
            // The store is the graph's foundation — without it there is
            // nothing to connect to a server *for*. The status item and its
            // Quit item stay up rather than the app dying silently at launch,
            // which at least leaves something to quit and something to see.
            // A user-facing error belongs with the UI in the next plan; the
            // log is what exists today.
            //
            // Domain and code only, never `localizedDescription`: a Core
            // Data store-open failure embeds the store file's path.
            let ns = error as NSError
            Log.app.error("could not open the message store; running without connections: \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
        }
    }

    /// Quitting waits for the graph to stop, so the last batch a pump is
    /// holding is written and its notification raised before the process
    /// goes away (`AppGraph.stop()`'s contract).
    ///
    /// `.terminateLater` rather than `applicationWillTerminate`: that callback
    /// is synchronous and the process exits the moment it returns, so a
    /// `Task` started there would be killed mid-flush — the exact loss
    /// `ConnectionCoordinator.stop()` exists to prevent.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
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
