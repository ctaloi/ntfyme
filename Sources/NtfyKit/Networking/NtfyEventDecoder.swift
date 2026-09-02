import Foundation

/// Decodes a single ndjson line. Never throws: a bad line is data to report,
/// not a reason to tear down a live connection.
public struct NtfyEventDecoder: Sendable {
    public enum Outcome: Sendable, Equatable {
        case event(NtfyEvent)
        case ignoredUnknownEvent(String)
        case empty
        case malformed(line: String, error: String)
    }

    private let json = JSONDecoder()

    public init() {}

    public func decode(line: String) -> Outcome {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }

        do {
            let event = try json.decode(NtfyEvent.self, from: Data(trimmed.utf8))
            guard event.kind != nil else { return .ignoredUnknownEvent(event.event) }
            return .event(event)
        } catch {
            return .malformed(line: trimmed, error: String(describing: error))
        }
    }
}
