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

/// A received line re-arms the countdown, and the arm it replaced must never
/// fire — otherwise a healthy connection is torn down and rebuilt on a timer.
///
/// The shape here is deliberate, and it is a repair. The original asserted
/// `fired.hasFired == false` on the line after `advanceOnePendingSleep()`.
/// That is a negative assertion with nothing behind it: advancing only
/// *resumes* the sleeping task, which then still has to be scheduled, run
/// `fireIfStillArmed`, and hop to the `Signal` actor. The assertion ran before
/// any of that could happen, so it held whether or not the guard existed —
/// verified by mutation, it passed against a watchdog with the guard removed.
///
/// A negative assertion is only evidence when something positive and causally
/// later proves the forbidden path had its chance. That is the live arm below:
/// it is released *after* the superseded one and its fire is awaited, so by the
/// time `fireCount` is read the stale arm has been resumed, scheduled, and run.
/// Against the broken watchdog this reads 2. It also covers, incidentally, that
/// `pet()` re-arms rather than merely cancelling — nothing else does.
@Test func doesNotFireWhileLinesKeepArriving() async throws {
    let sleeper = ManualSleeper()
    let watchdog = KeepaliveWatchdog(timeout: .seconds(90), sleeper: sleeper)
    let fired = Signal()

    await watchdog.start { await fired.signal() }
    await sleeper.waitForPendingSleeps(atLeast: 1)
    await watchdog.pet()
    // The re-armed timer registers its sleep from inside a `Task`, so wait for
    // it rather than advancing into a queue it has not reached yet.
    await sleeper.waitForPendingSleeps(atLeast: 2)

    // Oldest first: the superseded arm, then the live one.
    await sleeper.advanceOnePendingSleep()
    await sleeper.advanceOnePendingSleep()

    // `waitOrTimeout` alone would be satisfied by *either* arm, so it proves
    // only that the fire path works and the executor has drained. The settle
    // window then lets any second fire land before the count is read — the
    // same construction `startingTwiceSupersedesTheFirstTimer` uses below, and
    // the reason the count is meaningful rather than merely early.
    #expect(await fired.waitOrTimeout() == true)
    try await Task.sleep(for: .milliseconds(50))
    #expect(await fired.fireCount == 1)
    await watchdog.stop()
}

/// After `stop()`, the arm that was in flight must never fire — a stopped
/// connection that still reconnects itself on a timer is invisible until it
/// isn't.
///
/// Repaired the same way and for the same reason as
/// `doesNotFireWhileLinesKeepArriving` above: the original read `hasFired`
/// immediately after the advance and so passed against a broken watchdog. The
/// fresh arm below is the positive control — released after the stopped one and
/// awaited, so the stopped arm has demonstrably had its chance by the time the
/// counts are read.
///
/// Two signals rather than one, because `fireIfStillArmed` looks up
/// `currentHandler` dynamically: a stopped arm that fires *before* the fresh
/// `start` runs its own closure and shows up on `stale`, while one that fires
/// *after* runs the replacement's and shows up as a second count on `live`.
/// One shared signal would leave those two orderings indistinguishable, and the
/// first version of this repair used one and passed against a broken build in
/// 0.002s — `waitOrTimeout` had been satisfied by the forbidden fire itself.
@Test func stopPreventsAnyFurtherFiring() async throws {
    let sleeper = ManualSleeper()
    let watchdog = KeepaliveWatchdog(timeout: .seconds(90), sleeper: sleeper)
    let stale = Signal()
    let live = Signal()

    await watchdog.start { await stale.signal() }
    await sleeper.waitForPendingSleeps(atLeast: 1)
    await watchdog.stop()
    await sleeper.advanceOnePendingSleep()

    // A fresh arm, after the stopped one was released. `advanceOnePendingSleep`
    // removed the stopped arm's continuation, so `atLeast: 1` here waits for
    // this new arm's sleep rather than returning on the old one.
    await watchdog.start { await live.signal() }
    await sleeper.waitForPendingSleeps(atLeast: 1)
    await sleeper.advanceOnePendingSleep()

    #expect(await live.waitOrTimeout() == true)
    try await Task.sleep(for: .milliseconds(50))
    #expect(await stale.fireCount == 0)
    #expect(await live.fireCount == 1)
    await watchdog.stop()
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
            // Explicit `do`/`catch` rather than `try?`, matching the other wait
            // helpers in this suite: a cancelled poll means the test task
            // itself is going away, and `try?` would spin out the remaining
            // iterations instead of stopping.
            do { try await Task.sleep(for: .milliseconds(10)) } catch { break }
        }
        return hasFired
    }
}
