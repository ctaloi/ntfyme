import Foundation

/// One-shot history fetch for a newly added topic (spec §5).
///
/// It must poll the single topic, not the shared multi-topic stream: a topic
/// with no watermark would otherwise drag the shared resume point to the epoch
/// and replay every other topic's entire cached history.
public struct Backfill: Sendable {
    private let endpoint: NtfyEndpoint
    private let client: any StreamClient
    private let store: MessageStore

    public init(endpoint: NtfyEndpoint, client: any StreamClient, store: MessageStore) {
        self.endpoint = endpoint
        self.client = client
        self.store = store
    }

    /// Fetches and stores the topic's server-cached history. Returns the number
    /// of rows inserted. The topic's watermark is set as a side effect of the
    /// insert, which is what makes the subsequent stream rebuild safe.
    @discardableResult
    public func run(topic: String, serverID: UUID) async throws -> Int {
        let request = try endpoint.pollRequest(topic: topic, since: .all)
        var events: [NtfyEvent] = []

        for try await element in client.stream(request) {
            switch element {
            case .event(let event):
                if event.kind == .message { events.append(event) }
            case .skippedLine(let reason):
                Log.stream.warning("skipped line: \(reason, privacy: .public)")
            }
        }

        let result = try await store.insert(events, serverID: serverID)
        Log.store.info("backfilled \(result.inserted, privacy: .public) messages for a new topic")
        return result.inserted
    }
}
