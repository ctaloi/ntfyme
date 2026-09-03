import AppKit
import SwiftUI
import NtfyKit

/// Owns the Settings window and the SwiftUI tree inside it.
///
/// **Why this exists rather than the standard `Settings` scene.** The app is a
/// menu-bar accessory: usually not the active application, frequently with no
/// key window at all. Opening the `Settings` scene means sending
/// `showSettingsWindow:` down the responder chain, and from that state nothing
/// on the chain handles it — measured on a real launch, the action returned
/// false, both selectors failed, and the window simply never appeared. Settings
/// is where a server gets added, so the app could not be configured at all.
///
/// Hosting the window directly removes the dependency on being active. It is
/// the same shape `HistoryWindowController` already uses, so there is now one
/// pattern for both windows instead of two.
///
/// Like that controller, this deliberately does not touch
/// `NSApp.activationPolicy` — that is app-wide state owned by
/// `ActivationPolicyController`.
@MainActor
final class SettingsWindowController {
    private let model: SettingsModel
    private var window: NSWindow?

    init(model: SettingsModel) {
        self.model = model
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.title = "NtfyMe Settings"
        window.center()
        window.setFrameAutosaveName("SettingsWindow")
        // The window outlives a close so reopening keeps its position and the
        // model's loaded state; without this AppKit would deallocate it and
        // `window` would dangle.
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
