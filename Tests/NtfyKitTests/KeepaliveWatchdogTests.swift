import Testing
@testable import NtfyKit

@Test func firesWhenNoLineArrivesWithinTheTimeout() async throws {
    let sleeper = ManualSleeper()
    let watchdog = KeepaliveWatchdog(timeout: .seconds(90), sleeper: sleeper)
    let fired = Signal()

    await watchdog.start { await fired.signal() }
    await sleeper.waitForPendingSleep()
    await sleeper.advanceOnePendingSleep()

    #expect(await fired.waitOrTimeout() == true)
}

@Test func doesNotFireWhileLinesKeepArriving() async throws {
    let sleeper = ManualSleeper()
    let watchdog = KeepaliveWatchdog(timeout: .seconds(90), sleeper: sleeper)
    let fired = Signal()

    await watchdog.start { await fired.signal() }
    await sleeper.waitForPendingSleep()
    await watchdog.pet()
    await sleeper.advanceOnePendingSleep()

    #expect(await fired.hasFired == false)
    await watchdog.stop()
}

@Test func stopPreventsAnyFurtherFiring() async throws {
    let sleeper = ManualSleeper()
    let watchdog = KeepaliveWatchdog(timeout: .seconds(90), sleeper: sleeper)
    let fired = Signal()

    await watchdog.start { await fired.signal() }
    await sleeper.waitForPendingSleep()
    await watchdog.stop()
    await sleeper.advanceOnePendingSleep()

    #expect(await fired.hasFired == false)
}

/// A reconnect calls start() on a live watchdog with no intervening stop().
/// The second arm must supersede the first, not leave two live timers.
@Test func startingTwiceSupersedesTheFirstTimer() async throws {
    let sleeper = ManualSleeper()
    let watchdog = KeepaliveWatchdog(timeout: .seconds(90), sleeper: sleeper)
    let first = Signal()
    let second = Signal()

    await watchdog.start { await first.signal() }
    await sleeper.waitForPendingSleeps(atLeast: 1)
    await watchdog.start { await second.signal() }
    await sleeper.waitForPendingSleeps(atLeast: 2)

    // Release the superseded timer and the live one.
    await sleeper.advanceOnePendingSleep()
    await sleeper.advanceOnePendingSleep()

    #expect(await second.waitOrTimeout() == true)
    // `fireIfStillArmed` looks up `currentHandler` dynamically rather than
    // capturing the closure at arm time, so a stale, un-superseded timer
    // would invoke `second`'s closure too (currentHandler was overwritten by
    // the second start()), not `first`'s. Asserting first.hasFired == false
    // alone cannot distinguish that from correct behavior — both the correct
    // and the broken path leave `first` unfired. Counting `second`'s
    // invocations is what actually pins the invariant: exactly one arm may
    // ever call its handler; a superseded, still-live timer firing a second
    // time is the bug this test exists to catch.
    try await Task.sleep(for: .milliseconds(50))
    #expect(await first.hasFired == false)
    #expect(await second.fireCount == 1)
    await watchdog.stop()
}

/// Minimal async signal used only by these tests.
actor Signal {
    private(set) var fireCount = 0
    var hasFired: Bool { fireCount > 0 }
    func signal() { fireCount += 1 }
    func waitOrTimeout() async -> Bool {
        for _ in 0..<100 {
            if hasFired { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return hasFired
    }
}
