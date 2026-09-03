import Testing
import NtfyKit
@testable import NtfyMe

/// Pure-logic coverage for `ConnectionState.problemLabel`/`canRetry`
/// (`MenuBarModels.swift`). No rendering involved, so no
/// `requiresSnapshotRendering` — these run everywhere, including headless CI.
struct MenuBarModelsTests {
    @Test func openHasNoProblemLabel() {
        #expect(ConnectionState.open.problemLabel == nil)
    }

    @Test func unauthorizedIsNotRetryable() {
        #expect(ConnectionState.unauthorized.problemLabel == "Sign-in needed")
        #expect(!ConnectionState.unauthorized.canRetry)
    }

    @Test func everyOtherStateIsRetryable() {
        let states: [ConnectionState] = [
            .idle, .connecting, .backoff(attempt: 1),
            .degraded(reason: .rateLimited), .degraded(reason: .historyGap),
            .degraded(reason: .keepaliveTimeout), .degraded(reason: .invalidSince),
            .degraded(reason: .httpError(status: 503)), .degraded(reason: .unclassified),
            .degraded(reason: .network(.offline)),
        ]
        for state in states {
            #expect(state.canRetry, "\(state) should be retryable")
            #expect(state.problemLabel != nil, "\(state) should have a problem label")
        }
    }

    @Test func degradedReasonsHaveDistinctLabels() {
        #expect(ConnectionState.degraded(reason: .rateLimited).problemLabel == "Rate limited")
        #expect(ConnectionState.degraded(reason: .keepaliveTimeout).problemLabel == "Not responding")
        #expect(ConnectionState.degraded(reason: .httpError(status: 503)).problemLabel
                == "Server error (503)")
        #expect(ConnectionState.backoff(attempt: 4).problemLabel == "Retrying…")
    }

    @Test func networkFailuresHaveDistinctLabels() {
        #expect(ConnectionState.degraded(reason: .network(.offline)).problemLabel == "Offline")
        #expect(ConnectionState.degraded(reason: .network(.cannotFindHost)).problemLabel
                == "Can't find host")
        #expect(ConnectionState.degraded(reason: .network(.other(code: -1))).problemLabel
                == "Network error")
    }
}
