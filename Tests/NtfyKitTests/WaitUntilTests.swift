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
/// A quarter of the timeout keeps the discrimination the test exists for:
/// the buggy version returns at ~2s, twice the bound and eight times the
/// worst measurement seen; the fixed version returns in microseconds. What
/// is being asserted is "returned promptly rather than spinning out the
/// deadline", and that is a claim about the ratio, so the assertion is now
/// written as one.
@Test func waitUntilReturnsPromptlyWhenItsTaskIsCancelledRatherThanSpinningOutTheDeadline() async throws {
    let timeout = Duration.seconds(2)
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
