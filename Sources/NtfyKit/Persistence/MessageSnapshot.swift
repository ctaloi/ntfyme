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
    /// Decoded once, when the snapshot is built — not a computed property
    /// re-decoding on every access. Empty means "no actions", full stop: a
    /// decode failure is handled at construction (`Message.snapshot`), logged
    /// there, and never reaches here silently disguised as the same `[]`.
    public let actions: [NtfyAction]
    public let isRead: Bool

    public var isMarkdown: Bool { contentType == "text/markdown" }
    public var resolvedPriority: NtfyPriority { NtfyPriority(rawValue: priority) ?? .default }
}

extension Message {
    public var snapshot: MessageSnapshot {
        let actions: [NtfyAction]
        if let actionsJSON {
            do {
                actions = try JSONDecoder().decode([NtfyAction].self, from: actionsJSON)
            } catch {
                // A stored blob this app wrote itself; a decode failure means
                // the row is corrupt rather than "no actions were attached" —
                // those two cases must not collapse into the same silent `[]`.
                // The error itself is never logged: `DecodingError`'s
                // description quotes the offending data, which can carry an
                // action's `url`, `label`, or `body` — exactly the message
                // content spec §9 forbids in logs (see Log.swift).
                Log.store.error(
                    "failed to decode stored actions for message on server \(self.serverID.uuidString, privacy: .public)"
                )
                actions = []
            }
        } else {
            actions = []
        }

        return MessageSnapshot(id: uniqueKey, messageID: messageID, topic: topic,
                        serverID: serverID, time: time, title: title, body: body,
                        priority: priority, tags: tags, click: click,
                        iconURL: iconURL, contentType: contentType,
                        actionsJSON: actionsJSON, actions: actions, isRead: isRead)
    }
}
