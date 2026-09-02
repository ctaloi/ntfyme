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
/// cancelled sleep and returns almost immediately. A generous timeout
/// (2 seconds) against a tight elapsed-time bound (200ms) distinguishes the
/// two honestly — this fails on the buggy version rather than passing either
/// way.
@Test func waitUntilReturnsPromptlyWhenItsTaskIsCancelledRatherThanSpinningOutTheDeadline() async throws {
    let task = Task {
        await waitUntil(timeout: .seconds(2)) { false }
    }
    task.cancel()

    let start = ContinuousClock.now
    _ = await task.value
    let elapsed = ContinuousClock.now - start

    #expect(elapsed < .milliseconds(200))
}
