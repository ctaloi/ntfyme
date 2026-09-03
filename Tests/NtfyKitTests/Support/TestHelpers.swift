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
