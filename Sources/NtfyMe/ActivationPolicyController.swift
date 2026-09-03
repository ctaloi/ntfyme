import AppKit

/// Flips the app between `.accessory` (menu-bar only, no Dock icon) and
/// `.regular` (Dock icon, normal app menu) as user-facing windows open and
/// close.
///
/// `.regular` is the launch state and the resting state while any window is
/// open — the app delegate sets it, and this only ever *demotes* once the
/// last window closes, so the app keeps running in the menu bar. That is the
/// reverse of the original spec §7 shape (menu-bar-first, `.accessory` at
/// rest), changed when the app became native-first in d4b82ac; `start()`'s
/// doc comment covers why the difference matters at launch.
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

    /// Begins observing. **Deliberately does not apply a policy**: it adopts
    /// whatever the app delegate has already set, and only reacts from here.
    ///
    /// This used to end with an `update()`, which was a launch bug. At
    /// `applicationDidFinishLaunching` time no window has been opened yet, so
    /// that recomputation could only ever conclude `.accessory` — demoting
    /// the app microseconds after the delegate deliberately set `.regular`,
    /// and promoting it back a few statements later when `openHistory()` ran.
    ///
    /// Reported as: the app launches, but its window is not selected and it
    /// takes several clicks or ⌥⇥ to make it active. Changing activation
    /// policy during launch is what does that — the window is ordered front
    /// while the app never wins activation, so it looks open and behaves as
    /// though it is in the background. `NSApp.activate()` from the window
    /// controller cannot rescue it, because the churn happens around the
    /// activation rather than instead of it.
    ///
    /// The invariant that made this inevitable is pinned by
    /// `noWindowsMeansNoDockIcon`: with no windows the answer is always
    /// `.accessory`, so calling `update()` before the first window exists is
    /// never anything but a demotion.
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
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    /// Call directly when opening a window, so the Dock icon and menu bar
    /// appear as the window does rather than one notification later.
    func update() {
        let wantsRegular = Self.wantsRegular(
            windows: NSApp.windows.map { ($0.isVisible, $0.canBecomeMain) })
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

    /// The policy decision, split out from AppKit so it can be tested without
    /// a window server. `true` means the app should show a Dock icon.
    ///
    /// Both conditions are required. `isVisible` alone would keep the Dock
    /// icon after a window is ordered out, and `canBecomeMain` alone would
    /// summon one for the status item's window and the popover's window,
    /// which are real `NSWindow`s that are frequently visible.
    nonisolated static func wantsRegular(
        windows: [(isVisible: Bool, canBecomeMain: Bool)]
    ) -> Bool {
        windows.contains { $0.isVisible && $0.canBecomeMain }
    }

}
