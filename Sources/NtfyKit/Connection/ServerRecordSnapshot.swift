import Foundation

/// A `Sendable` view of one `Server` row and its subscriptions.
///
/// `@Model` classes are not `Sendable` and must not cross an actor boundary,
/// so the coordinator is handed one of these rather than a `Server`.
public struct ServerRecordSnapshot: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let name: String
    public let baseURL: URL
    public let authKindRaw: String
    /// §5.2's resume point, as persisted. Seeding a new connection with this is
    /// what stops a quiet topic replaying its whole cache on every launch.
    public let caughtUpTo: Date?
    public let cacheWindowSeconds: Double
    public let watermarks: [TopicWatermark]
    public let sortOrder: Int

    public var topics: [String] { watermarks.map(\.topic) }

    public init(id: UUID, name: String, baseURL: URL, authKindRaw: String,
                caughtUpTo: Date?, cacheWindowSeconds: Double,
                watermarks: [TopicWatermark], sortOrder: Int) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.authKindRaw = authKindRaw
        self.caughtUpTo = caughtUpTo
        self.cacheWindowSeconds = cacheWindowSeconds
        self.watermarks = watermarks
        self.sortOrder = sortOrder
    }
}
