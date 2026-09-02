import Foundation
@testable import NtfyKit

/// Deterministic `StreamClient`. Each `stream(_:)` call consumes one queued
/// script; an exhausted queue yields an empty, immediately-finished stream,
/// which `ServerConnection` treats as a clean disconnect.
actor FakeStreamClient: StreamClient {
    private enum Script {
        case elements([NtfyStreamClient.StreamElement])
        case failure(Swift.Error)
        /// Never yields and never finishes on its own — for pinning a
        /// caller's timeout against a server that accepts the connection and
        /// then stalls. Only ends when the consumer's task is cancelled,
        /// which tears down the stream via `onTermination` below.
        case hang
    }

    private var scripts: [Script] = []
    /// Updated inside the `Task` spawned by `stream(_:)`, not synchronously
    /// within it — `take(_:)` is an actor hop away from the `nonisolated`
    /// call. So these lag a `stream(_:)` call by one hop: never read either
    /// immediately after `start()` without polling (`waitUntil`) for the
    /// value to land.
    private(set) var requestCount = 0
    private(set) var lastRequest: URLRequest?

    func enqueue(_ elements: [NtfyStreamClient.StreamElement]) {
        scripts.append(.elements(elements))
    }

    func enqueueError(_ error: Swift.Error) {
        scripts.append(.failure(error))
    }

    func enqueueHang() {
        scripts.append(.hang)
    }

    private func take(_ request: URLRequest) -> Script {
        requestCount += 1
        lastRequest = request
        return scripts.isEmpty ? .elements([]) : scripts.removeFirst()
    }

    nonisolated func stream(
        _ request: URLRequest
    ) -> AsyncThrowingStream<NtfyStreamClient.StreamElement, Swift.Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                switch await self.take(request) {
                case .elements(let elements):
                    for element in elements { continuation.yield(element) }
                    continuation.finish()
                case .failure(let error):
                    continuation.finish(throwing: error)
                case .hang:
                    // `try?`: cancellation is the only way this returns, and
                    // that is the intended, sole exit for this branch — there
                    // is nothing else to report.
                    try? await Task.sleep(for: .seconds(86400))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
