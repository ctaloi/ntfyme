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

    func show() {
        if openWindow() {
            Task { await viewModel.loadSidebar() }
            Task { await viewModel.refreshMessages() }
        }
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
        if openWindow() {
            // `reveal` does not touch the sidebar — it only widens
            // scope/filters and loads the target message — so a fresh
            // window still needs this once, the same as plain `show()`.
            // Not awaited here for the same reason `show()` does not await
            // it: the sidebar filling in a moment after the window opens is
            // fine, and blocking the reveal on it would not be.
            Task { await viewModel.loadSidebar() }
        }
        await viewModel.reveal(messageKey: messageKey)
    }

    func close() {
        window?.close()
    }

    /// Creates the window on first call, brings an existing one forward
    /// otherwise. Returns whether this call created it, so a caller can
    /// decide what else a *fresh* window still needs (the sidebar's initial
    /// load) without duplicating the window-creation code itself.
    @discardableResult
    private func openWindow() -> Bool {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return false
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
        window.contentView = NSHostingView(rootView: HistoryView(viewModel: viewModel))
        self.window = window

        window.makeKeyAndOrderFront(nil)
        return true
    }
}
