import Foundation
@testable import NtfyKit

/// Deterministic `StreamClient`. Each `stream(_:)` call consumes one queued
/// script; an exhausted queue yields an empty, immediately-finished stream,
/// which `ServerConnection` treats as a clean disconnect.
actor FakeStreamClient: StreamClient {
    private enum Script {
        case elements([NtfyStreamClient.StreamElement])
        case failure(Swift.Error)
    }

    private var scripts: [Script] = []
    private(set) var requestCount = 0
    private(set) var lastRequest: URLRequest?

    func enqueue(_ elements: [NtfyStreamClient.StreamElement]) {
        scripts.append(.elements(elements))
    }

    func enqueueError(_ error: Swift.Error) {
        scripts.append(.failure(error))
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
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
