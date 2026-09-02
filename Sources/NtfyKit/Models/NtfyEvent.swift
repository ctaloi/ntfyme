import Foundation

/// One decoded line from an ntfy ndjson stream.
///
/// `event` is kept as a raw `String` rather than decoded straight into `Kind`
/// so that an event type introduced by a future server version decodes
/// successfully and is simply ignored, instead of throwing and killing the
/// stream. Callers switch on `kind` and skip `nil`.
public struct NtfyEvent: Codable, Sendable, Equatable {
    public enum Kind: String, Sendable {
        case open
        case message
        case keepalive
        case pollRequest = "poll_request"
    }

    public let id: String
    public let time: Int
    public let expires: Int?
    public let event: String
    public let topic: String
    public let title: String?
    public let message: String?
    public let priority: Int?
    public let tags: [String]?
    public let click: String?
    public let icon: String?
    public let contentType: String?
    public let actions: [NtfyAction]?
    public let attachment: NtfyAttachment?

    public var kind: Kind? { Kind(rawValue: event) }
    public var date: Date { Date(timeIntervalSince1970: TimeInterval(time)) }
    public var resolvedPriority: NtfyPriority { priority.flatMap(NtfyPriority.init(rawValue:)) ?? .default }
    public var isMarkdown: Bool { contentType == "text/markdown" }

    private enum CodingKeys: String, CodingKey {
        case id, time, expires, event, topic, title, message, priority
        case tags, click, icon, actions, attachment
        case contentType = "content_type"
    }
}
