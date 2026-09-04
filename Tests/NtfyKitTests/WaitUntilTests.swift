import Foundation
import Testing
@testable import NtfyKit

/// Regression coverage for the cancellation branch of the shared `waitUntil`
/// helper (`Support/TestHelpers.swift`). A prior version swallowed
/// `Task.sleep`'s cancellation error with a bare `try?` and kept looping,
/// which spins at full CPU until the deadline elapses instead of returning
/// promptly. `Task.sleep` throws immediately (without actually sleeping) once
/// its task is cancelled, so the buggy loop's wall-clock time to return is
/// pinned to the full timeout; the fixed loop breaks out on the first
/// cancelled sleep and returns almost immediately.
///
/// **The bound is a fraction of the timeout, not an absolute duration.** It
/// was 200ms, which held for months and then failed on CI at 265ms — not
/// because anything regressed, but because a contended hosted runner is
/// slower than a developer machine. An absolute bound on a machine-speed
/// measurement tests the machine as much as the code.
///
/// Making the bound a ratio was necessary but not sufficient, and it went on
/// to fail at 1.02s and 0.61s against a 2s timeout's quarter-bound of 0.5s.
/// The reason is that the two sides of the ratio do not scale together. On
/// the cancelled path `waitUntil` breaks out of its loop on the first
/// `Task.sleep` throw, so what `elapsed` measures is how long the runner
/// took to schedule and resume the task — a constant of the machine, which
/// does not shrink when the timeout does. The buggy version, by contrast,
/// returns at exactly the timeout.
///
/// So the timeout is the knob that buys headroom on both sides at once: it
/// widens the absolute bound while leaving the fixed implementation's
/// measurement where it was. At 8s the bound is 2s — twice the worst
/// scheduling latency observed on CI, and a quarter of the 8s a regression
/// would take. The cost is that a genuine regression takes 8s to fail.
@Test func waitUntilReturnsPromptlyWhenItsTaskIsCancelledRatherThanSpinningOutTheDeadline() async throws {
    let timeout = Duration.seconds(8)
    let task = Task {
        await waitUntil(timeout: timeout) { false }
    }
    task.cancel()

    let start = ContinuousClock.now
    _ = await task.value
    let elapsed = ContinuousClock.now - start

    #expect(elapsed < timeout / 4,
            "returned in \(elapsed), which is not promptly relative to the \(timeout) deadline — the cancelled sleep is being swallowed and the loop is spinning out the timeout.")
}
