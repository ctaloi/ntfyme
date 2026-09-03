import Foundation
import SwiftData

/// One configured ntfy server.
///
/// Credentials are NOT here. They live in the Keychain keyed by `id` (spec §9),
/// so this record can be exported or inspected without leaking one.
@Model
public final class Server {
    @Attribute(.unique) public var id: UUID
    public var name: String
    public var baseURLString: String
    /// `AuthCredential`'s case name; the value itself is in the Keychain.
    public var authKindRaw: String
    public var sortOrder: Int
    /// §5.2: everything up to here has been delivered on every topic of this
    /// server. Persisted so a restart resumes correctly rather than replaying.
    public var caughtUpTo: Date?
    /// Server-side cache window. ntfy.sh is 12h; self-hosted servers vary, so
    /// it belongs on the server rather than as a client-wide constant.
    public var cacheWindowSeconds: Double

    @Relationship(deleteRule: .cascade, inverse: \Subscription.server)
    public var subscriptions: [Subscription]

    public init(id: UUID = UUID(), name: String, baseURLString: String,
                authKindRaw: String = "unauthenticated", sortOrder: Int = 0,
                caughtUpTo: Date? = nil, cacheWindowSeconds: Double = 12 * 3600) {
        self.id = id
        self.name = name
        self.baseURLString = baseURLString
        self.authKindRaw = authKindRaw
        self.sortOrder = sortOrder
        self.caughtUpTo = caughtUpTo
        self.cacheWindowSeconds = cacheWindowSeconds
        self.subscriptions = []
    }

    public var baseURL: URL? { URL(string: baseURLString) }
}

/// One topic on one server.
@Model
public final class Subscription {
    @Attribute(.unique) public var id: UUID
    public var topic: String
    public var displayName: String?
    public var server: Server?
    /// Diagnostics and log correlation only — `since` is built from time
    /// (spec §5.1), because an unresolvable id returns a silent full replay.
    public var lastMessageID: String?
    public var lastMessageTime: Date?
    public var muted: Bool
    /// Record without alerting below this priority (1...5).
    public var minAlertPriority: Int
    public var symbolName: String?
    public var accentColorHex: String?

    public init(id: UUID = UUID(), topic: String, displayName: String? = nil,
                server: Server? = nil, lastMessageID: String? = nil,
                lastMessageTime: Date? = nil, muted: Bool = false,
                minAlertPriority: Int = 1, symbolName: String? = nil,
                accentColorHex: String? = nil) {
        self.id = id
        self.topic = topic
        self.displayName = displayName
        self.server = server
        self.lastMessageID = lastMessageID
        self.lastMessageTime = lastMessageTime
        self.muted = muted
        self.minAlertPriority = minAlertPriority
        self.symbolName = symbolName
        self.accentColorHex = accentColorHex
    }

    public var watermark: TopicWatermark {
        TopicWatermark(topic: topic, lastMessageTime: lastMessageTime)
    }
}

/// One received message. `uniqueKey` is what makes replay-on-reconnect safe.
@Model
public final class Message {
    @Attribute(.unique) public var uniqueKey: String
    public var messageID: String
    public var topic: String
    public var serverID: UUID
    public var time: Date
    public var expires: Date?
    public var title: String?
    public var body: String
    public var priority: Int
    /// `[String]` is stored by SwiftData as a transformable blob, not a
    /// SQL-queryable column: a `#Predicate` using `Array.contains` against
    /// this property does not just fail to filter, it crashes the process
    /// outright — confirmed down to the bare-literal case
    /// (`message.tags.contains("literal")`, no captured variable, no
    /// optional handling involved). Never write a predicate against `tags`
    /// directly; see `tagsJoined` below for how tag filtering does this
    /// instead, and reach for the same "join to a searchable `String`"
    /// pattern for any other array-typed attribute that needs to be
    /// predicate-filterable.
    public var tags: [String]
    /// Denormalized `tags`, delimited as `"|tag1|tag2|"` (empty string when
    /// no tag survives encoding — see `joinTags`) purely so
    /// `MessageStore.search`'s tag filter can push a plain `String.contains`
    /// predicate to SQL — the same shape `searchText` already pushes
    /// successfully — instead of fetching every row into memory to filter
    /// in Swift. Not meant to be read directly by anything other than that
    /// predicate; `tags` is still the source of truth for display.
    ///
    /// **The default is load-bearing and must not be removed.** This app ships
    /// no `VersionedSchema` or `SchemaMigrationPlan`, so it relies on
    /// lightweight migration. Adding a non-optional attribute with no default
    /// is the canonical case lightweight migration cannot infer: Core Data
    /// fails the store open outright with "Validation error missing attribute
    /// values on mandatory destination attribute", `AppGraph.init()` throws,
    /// and the user's entire archive becomes unreachable. Measured against a
    /// store written by the previous schema with rows in it, not assumed.
    ///
    /// With the default, an upgraded row arrives as `""` — searchable for
    /// nothing — and `prune`'s repair pass rewrites it from `tags` on its next
    /// run. That repair is only reachable because the store opens at all.
    public var tagsJoined: String = ""
    public var click: String?
    public var iconURL: String?
    public var contentType: String?
    /// `[NtfyAction]` as JSON. Kept opaque so an action kind ntfy adds later
    /// round-trips rather than being dropped.
    public var actionsJSON: Data?
    @Relationship(deleteRule: .cascade) public var attachment: Attachment?
    public var isRead: Bool

    public static func uniqueKey(serverID: UUID, topic: String, messageID: String) -> String {
        "\(serverID.uuidString)/\(topic)/\(messageID)"
    }

    /// Builds `tagsJoined` from `tags`. The leading AND trailing `"|"`
    /// matter: without them, a search for `"alert"` would also match a
    /// message tagged only `"alerts"`, since `"tag1|alerts|tag3".contains
    /// ("alert")` is true. With them, `"|alert|"` cannot be a substring of
    /// `"|alerts|"`.
    ///
    /// A tag containing `"|"` would break that delimiter scheme — it could
    /// make two adjacent, unrelated tags look like a match for a third. ntfy
    /// tags are comma-separated in the wire protocol, so `"|"` should never
    /// actually appear in one; this is a defensive fallback for malformed
    /// input, not an expected path. Such a tag is rejected (dropped) from
    /// this joined form rather than escaped: escaping would add a second
    /// piece of code the search-side matcher must agree with, to guard
    /// against a case that should not arise. The tag is untouched in `tags`
    /// itself and still displays normally — it is just not findable via
    /// `MessageStore.search`'s tag filter.
    public static func joinTags(_ tags: [String]) -> String {
        let safe = tags.filter { !$0.contains("|") }
        guard !safe.isEmpty else { return "" }
        return "|" + safe.joined(separator: "|") + "|"
    }

    public init(serverID: UUID, topic: String, messageID: String, time: Date,
                expires: Date? = nil, title: String? = nil, body: String,
                priority: Int = 3, tags: [String] = [], click: String? = nil,
                iconURL: String? = nil, contentType: String? = nil,
                actionsJSON: Data? = nil, attachment: Attachment? = nil,
                isRead: Bool = false) {
        self.uniqueKey = Message.uniqueKey(serverID: serverID, topic: topic, messageID: messageID)
        self.serverID = serverID
        self.topic = topic
        self.messageID = messageID
        self.time = time
        self.expires = expires
        self.title = title
        self.body = body
        self.priority = priority
        self.tags = tags
        self.tagsJoined = Message.joinTags(tags)
        self.click = click
        self.iconURL = iconURL
        self.contentType = contentType
        self.actionsJSON = actionsJSON
        self.attachment = attachment
        self.isRead = isRead
    }
}

/// Attachment metadata. The FILE lives outside the database under
/// Application Support, so pruning reclaims real disk. `localFilename` is
/// `nil` until `AttachmentDownloader` actually downloads it and
/// `MessageStore.setAttachmentLocalFilename` records the result — a row
/// with attachment metadata but no local file is the normal state for a
/// message that arrived but was never (or not yet) downloaded.
@Model
public final class Attachment {
    public var name: String
    public var urlString: String
    public var type: String?
    public var size: Int?
    public var expires: Date?
    public var localFilename: String?

    public init(name: String, urlString: String, type: String? = nil,
                size: Int? = nil, expires: Date? = nil, localFilename: String? = nil) {
        self.name = name
        self.urlString = urlString
        self.type = type
        self.size = size
        self.expires = expires
        self.localFilename = localFilename
    }
}
