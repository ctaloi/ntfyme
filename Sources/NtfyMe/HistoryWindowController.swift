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

    init(store: MessageStore) {
        viewModel = HistoryViewModel(store: store)
    }

    /// Injected by the wiring pass once `ConnectionCoordinator` (or an
    /// equivalent) can answer it. See `HistoryConnectionStatus`'s doc comment.
    func setStatusProvider(_ provider: @escaping (UUID) -> HistoryConnectionStatus) {
        viewModel.statusProvider = provider
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
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
        window.contentView = NSHostingView(rootView: HistoryView(viewModel: viewModel))
        self.window = window

        window.makeKeyAndOrderFront(nil)
        Task { await viewModel.loadSidebar() }
        Task { await viewModel.refreshMessages() }
    }

    func close() {
        window?.close()
    }
}
