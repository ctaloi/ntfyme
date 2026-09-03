import Testing
@testable import NtfyMe

/// The fan-out that replaced four point-to-point "tell that surface it went
/// stale" closures. See `StoreChangeBroadcast` for the four bugs.

@MainActor
@Test func postReachesEveryObserverInRegistrationOrder() async {
    let broadcast = StoreChangeBroadcast()
    // `nonisolated(unsafe)`: this test and every observer are on the same
    // `@MainActor`, and `post()` awaits each in turn — never concurrently.
    nonisolated(unsafe) var calls: [String] = []
    broadcast.observe { calls.append("sidebar") }
    broadcast.observe { calls.append("menu bar") }

    await broadcast.post()

    // Not just "both were called": one surface's refresh failing to happen
    // is the entire bug class this type exists for, and a deterministic
    // order is what makes that assertable rather than flaky.
    #expect(calls == ["sidebar", "menu bar"])

    await broadcast.post()
    #expect(calls == ["sidebar", "menu bar", "sidebar", "menu bar"])
}

/// `SettingsModel` posts on every successful write, including writes made
/// before `AppDelegate` has finished building the surfaces that observe —
/// `seedDefaultServerIfNeeded` runs from `SettingsView`'s `.task`. A post
/// with nothing registered has to be inert rather than an error.
@MainActor
@Test func postWithNoObserversIsInert() async {
    await StoreChangeBroadcast().post()
}
