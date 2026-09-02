import Foundation

/// Decodes a single ndjson line. Never throws: a bad line is data to report,
/// not a reason to tear down a live connection.
public struct NtfyEventDecoder: Sendable {
    public enum Outcome: Sendable, Equatable {
        case event(NtfyEvent)
        case ignoredUnknownEvent(String)
        case empty
        /// The line could not be decoded.
        ///
        /// The line itself is deliberately not carried. It may contain a
        /// message body, which spec §9 treats as sensitive, and a public type
        /// that carries one invites the next caller to log it — the reason the
        /// only current consumer strips it is not a property the type enforces.
        /// `reason` is drawn from a closed vocabulary describing the decoding
        /// failure's *shape*: key names and coding paths, which are schema,
        /// never content.
        case malformed(reason: String)
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
            return .malformed(reason: Self.reason(for: error))
        }
    }

    /// Describes a decoding failure without quoting the line.
    ///
    /// `String(describing:)` on a `DecodingError` is not safe to keep: for a
    /// truncated or non-JSON line the underlying `NSError` quotes the offending
    /// character and its column out of the input (measured: "Unexpected
    /// character 'o' in expected null value around line 1, column 2."). That is
    /// a fragment of the payload, so it is dropped in favour of a fixed label.
    private static func reason(for error: Swift.Error) -> String {
        guard let decoding = error as? DecodingError else { return "decode failure" }
        switch decoding {
        case .dataCorrupted:
            return "not valid JSON"
        case .keyNotFound(let key, _):
            return "missing key: \(key.stringValue)"
        case .typeMismatch(_, let context):
            return "type mismatch at \(path(context))"
        case .valueNotFound(_, let context):
            return "missing value at \(path(context))"
        @unknown default:
            return "decode failure"
        }
    }

    private static func path(_ context: DecodingError.Context) -> String {
        let path = context.codingPath.map(\.stringValue).joined(separator: ".")
        return path.isEmpty ? "top level" : path
    }
}
