import Foundation

/// A `Sendable` view of one `Message`.
///
/// `@Model` classes are not `Sendable` and must never cross an actor boundary
/// under Swift 6 strict concurrency. Every value the store hands out is one of
/// these instead.
public struct MessageSnapshot: Sendable, Equatable, Identifiable {
    public let id: String            // the uniqueKey
    public let messageID: String
    public let topic: String
    public let serverID: UUID
    public let time: Date
    public let title: String?
    public let body: String
    public let priority: Int
    public let tags: [String]
    public let click: String?
    public let iconURL: String?
    public let contentType: String?
    public let actionsJSON: Data?
    public let isRead: Bool

    public var isMarkdown: Bool { contentType == "text/markdown" }
    public var resolvedPriority: NtfyPriority { NtfyPriority(rawValue: priority) ?? .default }
    public var actions: [NtfyAction] {
        guard let actionsJSON else { return [] }
        // A stored blob this app wrote itself; a decode failure means the row
        // is corrupt, and an empty action list degrades the UI rather than
        // losing the message. Logged by the caller, not swallowed silently.
        return (try? JSONDecoder().decode([NtfyAction].self, from: actionsJSON)) ?? []
    }
}

extension Message {
    public var snapshot: MessageSnapshot {
        MessageSnapshot(id: uniqueKey, messageID: messageID, topic: topic,
                        serverID: serverID, time: time, title: title, body: body,
                        priority: priority, tags: tags, click: click,
                        iconURL: iconURL, contentType: contentType,
                        actionsJSON: actionsJSON, isRead: isRead)
    }
}
