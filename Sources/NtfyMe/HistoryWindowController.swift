import AppKit
import SwiftUI
import NtfyKit

/// Owns the History window's `NSWindow` and the SwiftUI tree it hosts.
///
/// Deliberately does not touch `NSApp.activationPolicy` — spec §7 has the app
/// run `.accessory` with no Dock icon and flip to `.regular` while a window
/// is open, but that policy is shared app-wide state a later wiring pass
/// coordinates across every window this app can open. This controller only
/// owns its own window; it exposes `show()`/`close()` for that pass to call.
@MainActor
final class HistoryWindowController {
    private let viewModel: HistoryViewModel
    private var window: NSWindow?
    /// Wired by `AppDelegate` to `openCompose()`, and read when the window's
    /// content view is built on first `show()`. Set it before then — which
    /// the delegate does, right where it creates this controller.
    var onNewMessage: () -> Void = {}

    /// - Parameter attachmentsDirectory: must be the exact same directory
    ///   `RetentionScheduler.attachmentsDirectory()` uses
    ///   (`Application Support/dev.aloi.NtfyMe/Attachments`), or Quick Look
    ///   previews resolve against the wrong place. `nil` — the default —
    ///   disables Quick Look entirely rather than guessing at the path.
    init(store: MessageStore, attachmentsDirectory: URL? = nil) {
        viewModel = HistoryViewModel(store: store, attachmentsDirectory: attachmentsDirectory)
    }

    /// Injected by the wiring pass once `ConnectionCoordinator` (or an
    /// equivalent) can answer it. See `HistoryConnectionStatus`'s doc comment.
    func setStatusProvider(_ provider: @escaping (UUID) -> HistoryConnectionStatus) {
        viewModel.statusProvider = provider
    }

    /// Loads on every call, not only when it creates the window: the app
    /// keeps running with no windows open (see `AppDelegate
    /// .applicationShouldTerminateAfterLastWindowClosed`), so "close History,
    /// receive ten messages, reopen it" was showing the ten-messages-ago
    /// state until the user touched a filter. Reopening a window is the
    /// clearest possible request for current data.
    func show() {
        openWindow()
        Task { await viewModel.loadSidebar() }
        Task { await viewModel.refreshMessages() }
    }

    /// Shows the window (creating it if needed, bringing an existing one
    /// forward either way — works on an already-open window with whatever
    /// scope/filters/selection it already has, same as `HistoryViewModel
    /// .reveal(messageKey:)` itself) and reveals one message in it. The
    /// entry point for both the menu bar popover's row tap
    /// (`MenuBarController.onOpenMessage`) and a notification click (spec
    /// §6: opens History scrolled to that message).
    ///
    /// `async` so a caller that wants the reveal to have actually finished
    /// — selection set, list scrolled — before doing anything else (e.g.
    /// activating the app) can await it; a caller that only wants to fire
    /// it and move on can just wrap the call in an unawaited `Task`.
    func show(revealing messageKey: String) async {
        openWindow()
        // `reveal` does not touch the sidebar — it only widens scope/filters
        // and loads the target message — so the sidebar is loaded here, on
        // every call for the same reason `show()` does. Not awaited, for the
        // same reason `show()` does not: the sidebar filling in a moment
        // after the window opens is fine, and blocking the reveal on it
        // would not be.
        Task { await viewModel.loadSidebar() }
        await viewModel.reveal(messageKey: messageKey)
    }

    func close() {
        window?.close()
    }

    /// Reloads the sidebar's servers/topics/unread counts from the store.
    /// Registered with `StoreChangeBroadcast` by `AppDelegate`, so any write
    /// anywhere in the app tells an already-open window "something changed,
    /// catch up" rather than it silently going stale until its next `show()`.
    /// `HistoryViewModel.loadSidebar()` already does the work; this only
    /// exposes it past `viewModel`'s own privacy.
    ///
    /// Safe with no window open at all — it only refreshes `viewModel`'s
    /// own state, not `window`, so there is nothing to be a no-op *about*:
    /// refreshing state nobody is currently displaying is inert, and means
    /// a later `show()` starts from data that is already current instead
    /// of a stale flash while it loads.
    func refreshSidebar() async {
        await viewModel.loadSidebar()
    }

    /// Creates the window on first call, brings an existing one forward
    /// otherwise. Used to return whether it had created one, so a caller
    /// could load only for a fresh window; both callers now load either way,
    /// which is the point — see `show()`.
    private func openWindow() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            activate()
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "NtfyMe History"
        window.minSize = NSSize(width: 640, height: 400)
        window.center()
        window.setFrameAutosaveName("HistoryWindow")
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: HistoryView(
            viewModel: viewModel,
            onNewMessage: { [weak self] in self?.onNewMessage() }))
        self.window = window

        window.makeKeyAndOrderFront(nil)
        activate()
    }

    /// Brings the *application* forward, not just the window.
    ///
    /// Reported as "when I click on the application it shows it's in the
    /// foreground, but it isn't acting like it is" — the window came forward
    /// and the app was never activated, so it looked frontmost while having
    /// no keyboard focus.
    ///
    /// `makeKeyAndOrderFront` orders a window within this app; it does not
    /// make this app the active one. `SettingsWindowController` and
    /// `ComposeWindowController` have always called this, and the History
    /// window — the main one — never did. It got away with it while
    /// `ActivationPolicyController.update()` happened to activate as a side
    /// effect of flipping `.accessory` → `.regular`; that flip stopped
    /// happening when the app started launching `.regular` (commit d4b82ac),
    /// and `update()` returns early when the policy is already what it
    /// wants, so nothing activated at all.
    private func activate() {
        NSApp.activate()
    }
}
