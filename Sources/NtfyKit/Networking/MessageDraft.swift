import Foundation

/// A message being composed, before it is published.
///
/// A plain value with no encoding of its own: the wire format is
/// `NtfyEndpoint.publishRequest`'s business, and this struct is also what the
/// Compose window's fields bind to, which is why every property is `var`.
///
/// Carries no server: `NtfyPublisher.publish` takes the base URL and the
/// credential explicitly (the Keychain lookup belongs to the caller that
/// owns server records), so a `serverID` here would be a field nothing
/// reads — and would force the Compose window to invent one before the user
/// has chosen a server. The draft is the message; where it goes is the
/// caller's.
///
/// `NtfyPriority` rather than `Int` so an out-of-range priority is
/// unrepresentable rather than something to validate — the receive side
/// already has to cope with whatever a server sends (`NtfyEvent
/// .resolvedPriority` falls back to `.default`), but nothing this app
/// *publishes* has any reason to be invalid in the first place.
public struct MessageDraft: Sendable, Equatable {
    public var topic: String
    /// `nil` or empty is a message with no title, which ntfy allows; the
    /// receive side then shows the topic instead (`NotificationDecision`,
    /// `HistoryRow.titleText`).
    public var title: String?
    public var body: String
    public var priority: NtfyPriority
    public var tags: [String]

    public init(topic: String = "", title: String? = nil,
                body: String = "", priority: NtfyPriority = .default,
                tags: [String] = []) {
        self.topic = topic
        self.title = title
        self.body = body
        self.priority = priority
        self.tags = tags
    }

    /// Whether this is enough of a message to send: a topic and a body.
    ///
    /// ntfy accepts a message with no title, so a title is not required. It
    /// does not accept one with no topic, and a publish with an empty body
    /// is a notification that says nothing — both are the user's to fix
    /// before the request is built, which is why this is here rather than
    /// expressed as an error thrown after a round trip.
    ///
    /// Does not check that the topic is *valid* — that is
    /// `NtfyEndpoint`'s rule (`[-_A-Za-z0-9]{1,64}`) and belongs with the
    /// one type that already enforces it for streams.
    public var isSendable: Bool {
        !topic.isEmpty && !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
