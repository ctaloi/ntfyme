import Testing
@testable import NtfyMe

/// The app runs `.accessory` (menu-bar only, no Dock icon) and flips to
/// `.regular` while a real window is open — spec §7. These pin the decision
/// itself; `update()`'s AppKit plumbing around it is not unit-testable
/// without a window server.

@Test func noWindowsMeansNoDockIcon() {
    #expect(ActivationPolicyController.wantsRegular(windows: []) == false)
}

@Test func aVisibleMainCapableWindowEarnsADockIcon() {
    #expect(ActivationPolicyController.wantsRegular(
        windows: [(isVisible: true, canBecomeMain: true)]) == true)
}

/// The status item's window and the popover's window are both real
/// `NSWindow`s and are routinely visible. If `canBecomeMain` were not part of
/// the test, simply having the menu bar up would summon a Dock icon and the
/// app would never be menu-bar-only at all.
@Test func aVisibleWindowThatCannotBecomeMainDoesNot() {
    #expect(ActivationPolicyController.wantsRegular(
        windows: [(isVisible: true, canBecomeMain: false)]) == false)
}

/// A window that has been ordered out but not deallocated still appears in
/// `NSApp.windows`. Without the `isVisible` half, closing the last window
/// would leave the Dock icon behind forever.
@Test func aHiddenMainCapableWindowDoesNot() {
    #expect(ActivationPolicyController.wantsRegular(
        windows: [(isVisible: false, canBecomeMain: true)]) == false)
}

/// The realistic shape: menu bar and popover up, History window closed.
@Test func statusItemAndPopoverAloneStayAccessory() {
    #expect(ActivationPolicyController.wantsRegular(windows: [
        (isVisible: true, canBecomeMain: false),   // status item
        (isVisible: true, canBecomeMain: false),   // popover
        (isVisible: false, canBecomeMain: true),   // History, closed
    ]) == false)
}

/// One real window among several non-qualifying ones is enough.
@Test func oneRealWindowAmongDecoysIsEnough() {
    #expect(ActivationPolicyController.wantsRegular(windows: [
        (isVisible: true, canBecomeMain: false),
        (isVisible: false, canBecomeMain: true),
        (isVisible: true, canBecomeMain: true),    // History, open
    ]) == true)
}

/// The launch ordering rule, stated as a test because the bug it prevents is
/// invisible in the decision function itself.
///
/// `applicationDidFinishLaunching` sets `.regular` and *then* starts this
/// controller, before any window has been opened. If `start()` recomputed at
/// that moment it would see no windows — the case pinned above — and demote
/// straight back to `.accessory`, only to promote again a few statements
/// later when the main window opens. That policy churn during launch is what
/// left the app running with its window ordered front but never actually
/// active: several clicks or ⌥⇥ to get into it.
///
/// So `start()` observes without applying, and this documents the invariant
/// that makes that necessary rather than merely tidy.
@Test func recomputingBeforeTheFirstWindowCanOnlyEverDemote() {
    // The exact state at `start()` time: whatever non-visible windows a
    // SwiftUI `Settings` scene has registered, and nothing else.
    #expect(ActivationPolicyController.wantsRegular(windows: []) == false)
    #expect(ActivationPolicyController.wantsRegular(
        windows: [(isVisible: false, canBecomeMain: true)]) == false)
}
