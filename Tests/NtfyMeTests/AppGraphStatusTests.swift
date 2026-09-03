import Testing
import NtfyKit
@testable import NtfyMe

/// The History sidebar's per-server dots. `AppGraph` polls
/// `ConnectionCoordinator` for these; this pins the mapping.

@Test func anUnfetchedServerIsUnknownRatherThanDisconnected() {
    // Not cosmetic: `.disconnected` renders an exclamation mark. Showing that
    // for a healthy server during the first refresh interval would make a
    // working app look broken every launch.
    #expect(AppGraph.historyStatus(for: nil) == .unknown)
}

@Test func openIsConnected() {
    #expect(AppGraph.historyStatus(for: .open) == .connected)
}

/// Backoff is a reconnect in progress, so it reads as `.connecting` rather
/// than `.disconnected` — the connection is coming back on its own and needs
/// no user attention.
@Test func connectingAndBackoffBothReadAsConnecting() {
    #expect(AppGraph.historyStatus(for: .connecting) == .connecting)
    #expect(AppGraph.historyStatus(for: .backoff(attempt: 1)) == .connecting)
    #expect(AppGraph.historyStatus(for: .backoff(attempt: 9)) == .connecting)
}

/// `.unauthorized` is terminal until credentials change and `.degraded` means
/// the stream is up but unhealthy. Both need the user to look, so both get
/// the attention-seeking state rather than a hopeful one.
@Test func idleDegradedAndUnauthorizedAllNeedAttention() {
    #expect(AppGraph.historyStatus(for: .idle) == .disconnected)
    #expect(AppGraph.historyStatus(for: .unauthorized) == .disconnected)
    #expect(AppGraph.historyStatus(for: .degraded(reason: .keepaliveTimeout)) == .disconnected)
}
