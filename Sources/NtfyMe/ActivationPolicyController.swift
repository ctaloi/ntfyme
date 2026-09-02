import AppKit

/// Flips the app between `.accessory` (menu-bar only, no Dock icon) and
/// `.regular` (Dock icon, normal app menu) as user-facing windows open and
/// close — spec §7's menubar-first behaviour.
///
/// This lives in one place on purpose. `HistoryWindowController`, the
/// Settings scene and the onboarding pane each own their own window and each
/// deliberately leaves the policy alone, because the policy is app-wide: if
/// two of them set it independently, closing either one would strip the Dock
/// icon while the other is still on screen.
///
/// **Why membership is computed rather than counted.** An earlier shape of
/// this held a counter incremented on open and decremented on close. A window
/// closed by the red button, by ⌘W, and by `close()` does not reliably
/// produce exactly one decrement each, so the count drifted and the Dock icon
/// either stuck around or vanished early. Asking AppKit what is actually on
/// screen cannot drift.
///
/// `canBecomeMain` is the discriminator: the status item's window and the
/// popover's window are both real `NSWindow`s and both report `isVisible`,
/// but neither can become main, so neither drags in a Dock icon.
@MainActor
final class ActivationPolicyController {
    private var observers: [NSObjectProtocol] = []

    func start() {
        let center = NotificationCenter.default
        for name in [NSWindow.willCloseNotification, NSWindow.didBecomeKeyNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // `willClose` fires while the window is still visible, so the
                // recomputation has to happen after AppKit has actually taken
                // it down — otherwise closing the last window always sees
                // itself and stays `.regular`.
                Task { @MainActor in self?.update() }
            })
        }
        update()
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    /// Call directly when opening a window, so the Dock icon and menu bar
    /// appear as the window does rather than one notification later.
    func update() {
        let wantsRegular = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
        let desired: NSApplication.ActivationPolicy = wantsRegular ? .regular : .accessory
        guard NSApp.activationPolicy() != desired else { return }
        NSApp.setActivationPolicy(desired)
        if desired == .regular {
            // Going `.accessory` → `.regular` does not focus the app on its
            // own; without this the new window opens behind whatever the user
            // was in.
            NSApp.activate()
        }
    }
}
