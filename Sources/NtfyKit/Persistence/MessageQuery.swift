import Foundation

/// Filter for a history query. All fields optional; nil means "no constraint".
public struct MessageQuery: Sendable, Equatable {
    public var serverID: UUID?
    public var topic: String?
    public var searchText: String?      // matches title or body, case-insensitive
    public var minPriority: Int?
    public var tag: String?
    public var unreadOnly: Bool
    public var since: Date?
    public var until: Date?
    public var limit: Int
    public var offset: Int

    public init(serverID: UUID? = nil, topic: String? = nil, searchText: String? = nil,
                minPriority: Int? = nil, tag: String? = nil, unreadOnly: Bool = false,
                since: Date? = nil, until: Date? = nil, limit: Int = 200, offset: Int = 0) {
        self.serverID = serverID
        self.topic = topic
        self.searchText = searchText
        self.minPriority = minPriority
        self.tag = tag
        self.unreadOnly = unreadOnly
        self.since = since
        self.until = until
        self.limit = limit
        self.offset = offset
    }
}

/// One row of the sidebar's unread badges.
public struct TopicSummary: Sendable, Equatable, Identifiable {
    public var id: String { "\(serverID.uuidString)/\(topic)" }
    public let serverID: UUID
    public let topic: String
    public let displayName: String?
    public let unreadCount: Int
    public let totalCount: Int
    public let lastMessageTime: Date?
    public let muted: Bool
    public let minAlertPriority: Int

    public init(serverID: UUID, topic: String, displayName: String?, unreadCount: Int,
                totalCount: Int, lastMessageTime: Date?, muted: Bool, minAlertPriority: Int) {
        self.serverID = serverID
        self.topic = topic
        self.displayName = displayName
        self.unreadCount = unreadCount
        self.totalCount = totalCount
        self.lastMessageTime = lastMessageTime
        self.muted = muted
        self.minAlertPriority = minAlertPriority
    }
}
