import AppKit
import SwiftUI
import NtfyKit

/// Owns the Compose window and the SwiftUI tree inside it.
///
/// Third instance of the shape `HistoryWindowController` and
/// `SettingsWindowController` already use, for the same reason the second
/// one exists: a window this app hosts directly does not depend on being
/// the active application or having a key window, which is what defeated
/// the SwiftUI `Settings` scene (see that controller's doc comment).
///
/// A window rather than a sheet on History: a message half-written should
/// survive closing that window, and this app deliberately outlives all of
/// its windows.
///
/// Like both siblings, does not touch `NSApp.activationPolicy` — that is
/// app-wide state owned by `ActivationPolicyController`.
@MainActor
final class ComposeWindowController {
    private let model: ComposeModel
    private var window: NSWindow?

    init(model: ComposeModel) {
        self.model = model
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "New Message"
        window.center()
        window.setFrameAutosaveName("ComposeWindow")
        // Outlives a close, so a draft survives closing the window and
        // reopening it — and so `window` does not dangle, which is what
        // AppKit would otherwise do here.
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ComposeView(
            model: model,
            // Sending closes the window. The confirmation the view shows is
            // for a send the user watches complete; once it has, the window
            // has done its job, and leaving it open invites sending the
            // same message twice. The draft's server, topic and priority
            // survive for the next one either way (`ComposeModel.send`).
            onSent: { [weak self] in self?.close() }))
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func close() {
        window?.close()
    }
}
