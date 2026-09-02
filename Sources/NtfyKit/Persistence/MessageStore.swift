import Foundation
import SwiftData

/// Owns the SwiftData container. Every public method takes and returns
/// `Sendable` value types — no `@Model` instance ever leaves this actor,
/// because `@Model` classes are not `Sendable`.
@ModelActor
public actor MessageStore {
    public struct InsertResult: Sendable, Equatable {
        public let inserted: Int
        public let duplicatesSkipped: Int
    }

    /// Persists the message events in `events`, skipping any whose
    /// `uniqueKey` is already stored, and advances each topic's watermark to
    /// the newest message time seen.
    ///
    /// Duplicates are filtered by an explicit query rather than by relying on
    /// the unique constraint alone — see this plan's "Measured SwiftData
    /// behavior" table for why.
    @discardableResult
    public func insert(_ events: [NtfyEvent], serverID: UUID) throws -> InsertResult {
        let messages = events.filter { $0.kind == .message }
        guard !messages.isEmpty else { return InsertResult(inserted: 0, duplicatesSkipped: 0) }

        let keys = Set(messages.map {
            Message.uniqueKey(serverID: serverID, topic: $0.topic, messageID: $0.id)
        })
        var existing = Set<String>()
        for key in keys {
            var descriptor = FetchDescriptor<Message>(
                predicate: #Predicate { $0.uniqueKey == key })
            descriptor.fetchLimit = 1
            if try modelContext.fetch(descriptor).first != nil { existing.insert(key) }
        }

        var inserted = 0
        var skipped = 0
        var newest: [String: Date] = [:]
        var newestID: [String: String] = [:]

        for event in messages {
            let key = Message.uniqueKey(serverID: serverID, topic: event.topic, messageID: event.id)
            if existing.contains(key) { skipped += 1; continue }
            existing.insert(key)

            modelContext.insert(Message(
                serverID: serverID,
                topic: event.topic,
                messageID: event.id,
                time: event.date,
                expires: event.expires.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                title: event.title,
                body: event.message ?? "",
                priority: event.priority ?? 3,
                tags: event.tags ?? [],
                click: event.click,
                iconURL: event.icon,
                contentType: event.contentType,
                // `try?`: `NtfyAction`'s stored properties are all `String`,
                // `Bool?`, or `[String: String]?` — none of JSONEncoder's
                // failure modes (non-finite floating point, non-string
                // dictionary keys) apply, so this cannot throw.
                actionsJSON: event.actions.flatMap { try? JSONEncoder().encode($0) }
            ))
            inserted += 1

            if newest[event.topic] == nil || event.date > newest[event.topic]! {
                newest[event.topic] = event.date
                newestID[event.topic] = event.id
            }
        }

        try advanceWatermarks(newest, ids: newestID, serverID: serverID)
        try modelContext.save()
        return InsertResult(inserted: inserted, duplicatesSkipped: skipped)
    }

    private func advanceWatermarks(_ newest: [String: Date], ids: [String: String],
                                   serverID: UUID) throws {
        for (topic, time) in newest {
            // Scoped to this server: two servers may both carry a topic of
            // the same name, and advancing the wrong one would make the other
            // resume from a point it never reached.
            guard let sub = try subscriptions(forServer: serverID)
                .first(where: { $0.topic == topic }) else {
                // A message arrived for a topic with no Subscription row —
                // the caller inserted it without subscribing first, or the
                // subscription was deleted mid-stream. There is nowhere to
                // store the watermark, so this topic replays in full on
                // every reconnect until a Subscription exists for it.
                Log.store.error("no subscription record for a message topic on server \(serverID.uuidString, privacy: .public)")
                continue
            }
            // A late arrival must never rewind the watermark, or the next
            // reconnect would replay everything after the older message.
            if sub.lastMessageTime == nil || time > sub.lastMessageTime! {
                sub.lastMessageTime = time
                sub.lastMessageID = ids[topic]
            }
        }
    }

    public func watermarks(forServer serverID: UUID) throws -> [TopicWatermark] {
        try subscriptions(forServer: serverID).map(\.watermark)
    }

    public func caughtUpTo(forServer serverID: UUID) throws -> Date? {
        try server(serverID)?.caughtUpTo
    }

    public func setCaughtUpTo(_ date: Date, forServer serverID: UUID) throws {
        guard let server = try server(serverID) else {
            // An unknown server id is a caller bug, the same as in
            // `subscriptions(forServer:)` — silently doing nothing here would
            // hide a caughtUpTo update that the caller believes succeeded.
            Log.store.error("no server record for the requested id")
            return
        }
        if server.caughtUpTo == nil || date > server.caughtUpTo! {
            server.caughtUpTo = date
            try modelContext.save()
        }
    }

    public func messages(forServer serverID: UUID, topic: String?,
                         limit: Int) throws -> [MessageSnapshot] {
        // The topic filter belongs IN the predicate. Applying `fetchLimit`
        // first and filtering afterwards would return fewer than `limit` rows
        // whenever other topics are interleaved — silently truncating a page.
        var descriptor: FetchDescriptor<Message>
        if let topic {
            descriptor = FetchDescriptor<Message>(
                predicate: #Predicate { $0.serverID == serverID && $0.topic == topic },
                sortBy: [SortDescriptor(\.time, order: .reverse)])
        } else {
            descriptor = FetchDescriptor<Message>(
                predicate: #Predicate { $0.serverID == serverID },
                sortBy: [SortDescriptor(\.time, order: .reverse)])
        }
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).map(\.snapshot)
    }

    public func messageCount() throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<Message>())
    }

    private func server(_ id: UUID) throws -> Server? {
        var descriptor = FetchDescriptor<Server>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func subscriptions(forServer serverID: UUID) throws -> [Subscription] {
        guard let server = try server(serverID) else {
            // An unknown server id is a caller bug, not an empty result to
            // paper over. Falling back to every subscription would silently
            // mix one server's topics into another's watermarks.
            Log.store.error("no server record for the requested id")
            return []
        }
        return server.subscriptions
    }
}
