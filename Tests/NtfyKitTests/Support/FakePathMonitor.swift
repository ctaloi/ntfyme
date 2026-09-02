import Foundation
@testable import NtfyKit

/// Deterministic `PathMonitoring`. `simulatePathSatisfied()` fires the callback
/// exactly once per call, so a test drives network changes rather than waiting
/// for a real interface to flap.
actor FakePathMonitor: PathMonitoring {
    private var handler: (@Sendable () async -> Void)?
    private(set) var startCount = 0
    private(set) var cancelCount = 0

    nonisolated func start(onSatisfied: @Sendable @escaping () async -> Void) {
        Task { await self.store(onSatisfied) }
    }

    nonisolated func cancel() {
        Task { await self.recordCancel() }
    }

    private func store(_ h: @Sendable @escaping () async -> Void) {
        handler = h
        startCount += 1
    }

    private func recordCancel() {
        handler = nil
        cancelCount += 1
    }

    func simulatePathSatisfied() async {
        await handler?()
    }
}
