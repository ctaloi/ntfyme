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
func waitUntil(
    timeout: Duration = .seconds(5),
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
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
