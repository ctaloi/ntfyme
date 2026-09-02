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

/// Minimal async signal used only by these tests.
actor Signal {
    private(set) var hasFired = false
    func signal() { hasFired = true }
    func waitOrTimeout() async -> Bool {
        for _ in 0..<100 {
            if hasFired { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return hasFired
    }
}
