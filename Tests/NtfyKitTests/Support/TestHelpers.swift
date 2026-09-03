import Foundation
import Testing
@testable import NtfyKit

extension Fixtures {
    /// Decode a fixture string into an `NtfyEvent`.
    static func decode(_ json: String) throws -> NtfyEvent {
        try JSONDecoder().decode(NtfyEvent.self, from: Data(json.utf8))
    }
}

/// Poll until `condition` holds or the deadline passes. Returns whether it
/// held. Bounded by construction: a test that would otherwise hang fails
/// instead, which on this project is a hard requirement.
/// How long `waitUntil` polls before giving up.
///
/// Five seconds is generous on a developer machine and was for a long time
/// generous everywhere. It stopped being so once this suite passed ~290
/// tests: on a hosted CI runner the same assertions began timing out in
/// bulk — seventeen `ServerConnectionTests`, nine `IngestTests`, and the
/// socket-level `MockNtfyServerTests` with them — while passing locally
/// every time.
///
/// The cause is contention, not correctness. The spec records that this
/// exact runner bound and served loopback fine when the suite was half this
/// size, and a helper asserting a 200ms cancellation bound was measured at
/// **1.674s** on it — roughly an eight-fold stall. A five-second deadline
/// under that is effectively six hundred milliseconds of real work.
///
/// So the deadline scales with the machine rather than the assertions being
/// weakened: every one of these still requires the condition to actually
/// become true, just with room for a slower host. A test that hangs still
/// fails; it simply takes longer to say so.
private let defaultWaitTimeout: Duration =
    ProcessInfo.processInfo.environment["CI"] == nil ? .seconds(5) : .seconds(30)

func waitUntil(
    timeout: Duration = defaultWaitTimeout,
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        do {
            try await Task.sleep(for: .milliseconds(10))
        } catch {
            // Cancelled: stop polling immediately rather than spinning out the
            // remaining deadline at full CPU.
            break
        }
    }
    return await condition()
}

/// Collects events from an `AsyncStream` without the test owning a mutable
/// local, which Swift 6 forbids capturing in a `Task`.
actor Collector {
    private var items: [NtfyEvent] = []
    var count: Int { items.count }
    var first: NtfyEvent? { items.first }
    func add(_ event: NtfyEvent) { items.append(event) }
}

/// Whether this process may create, mount, fill, and unmount a scratch
/// HFS+ disk image (`makeFullDiskFixture`/`fillVolume` in
/// `MessageStoreTests.swift`) — `false` on CI.
///
/// Same shape of problem `requiresSnapshotRendering` (`NtfyMeTests/
/// SnapshotSupport.swift`) already found and fixed for this suite: heavy
/// work running in parallel with the socket-level `MockNtfyServerTests`/
/// `ServerConnectionTests` starved them, not because either side was slow
/// on its own, but because CI has far less headroom than a dev machine.
/// The evidence here was a timestamp correlation, not a guess: every
/// `NSURLErrorCannotConnectToHost` (`-1004`) landed at the exact moment a
/// disk-exhaustion window closed. `waitUntil`'s CI deadline (see above)
/// already absorbed part of the contention — `IngestTests` and
/// `CaughtUpToTests` cleared entirely once it scaled — but
/// `ServerConnectionTests` and `MockNtfyServerTests` kept failing, now at
/// the full 30s wait rather than a shorter one: they were not slow, they
/// genuinely could not connect while the fixture held the machine.
///
/// `hdiutil create`/`attach`/`detach` and the disk-filling loop
/// (`Process.waitUntilExit()`, and many synchronous `FileHandle.write`
/// calls run to exhaustion) are synchronous, blocking calls made from
/// `async` test functions — each one occupies a Swift concurrency
/// cooperative-pool worker thread for its entire duration rather than
/// suspending it. On a developer machine with headroom to spare that is
/// invisible; on a CI runner with only a handful of cores, blocking even
/// one or two of those workers for the seconds a fill-to-exhaustion loop
/// takes can starve the whole pool, which is indistinguishable from the
/// loopback tests simply never getting scheduled — exactly the symptom
/// observed.
///
/// This test is not weakened by skipping it here, the same reasoning
/// `requiresSnapshotRendering` gives: it is a local verification tool for
/// a failure path (`insert`'s rollback-on-a-genuinely-full-disk behavior)
/// that nothing else in this suite covers, and what CI is for here is the
/// logic and networking it was drowning out. A skip reads as a skip in the
/// results, not a pass, so its absence on CI stays visible rather than
/// silently looking covered.
nonisolated let diskImageFixturesAreAvailable: Bool = {
    ProcessInfo.processInfo.environment["CI"] == nil
}()

let requiresDiskImageFixture = ConditionTrait.enabled(
    if: diskImageFixturesAreAvailable,
    "creates, mounts, and fills a scratch disk image; skipped on CI, where the synchronous hdiutil/FileHandle calls this needs starved the socket-level connection tests")
