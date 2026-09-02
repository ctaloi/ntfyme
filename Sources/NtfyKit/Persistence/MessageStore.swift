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
        guard let server = try server(serverID) else {
            // An unknown server id is a caller bug, the same as in
            // `subscriptions(forServer:)` and `setCaughtUpTo`. It matters
            // more here: `WatermarkResolver.resolve` treats `nil` with no
            // watermarks as "never synced" and returns a full cache replay —
            // silently indistinguishable from a genuinely new server.
            Log.store.error("no server record for the requested id")
            return nil
        }
        return server.caughtUpTo
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

    /// Every configured server, as `Sendable` snapshots, ordered by `sortOrder`.
    ///
    /// A row whose `baseURLString` does not parse is skipped and logged rather
    /// than throwing: one corrupt row must not stop every other server from
    /// connecting.
    public func servers() throws -> [ServerRecordSnapshot] {
        let rows = try modelContext.fetch(
            FetchDescriptor<Server>(sortBy: [SortDescriptor(\.sortOrder)]))

        return rows.compactMap { row in
            guard let url = row.baseURL else {
                Log.store.error("skipping a server row whose base URL does not parse")
                return nil
            }
            return ServerRecordSnapshot(
                id: row.id, name: row.name, baseURL: url,
                authKindRaw: row.authKindRaw, caughtUpTo: row.caughtUpTo,
                cacheWindowSeconds: row.cacheWindowSeconds,
                watermarks: row.subscriptions.map(\.watermark),
                sortOrder: row.sortOrder)
        }
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

    /// Applies both retention bounds and deletes the attachment files of every
    /// pruned message. Runs at launch and daily thereafter (spec §8).
    ///
    /// - Parameter attachmentsDirectory: where downloaded files live. `nil`
    ///   skips file deletion, for tests and for a build with no downloader.
    @discardableResult
    public func prune(policy: RetentionPolicy, now: Date = Date(),
                      attachmentsDirectory: URL?) throws -> PruneResult {
        let cutoff = now.addingTimeInterval(-policy.maxAge)
        var doomed: [Message] = []

        let tooOld = FetchDescriptor<Message>(predicate: #Predicate { $0.time < cutoff })
        doomed.append(contentsOf: try modelContext.fetch(tooOld))

        let doomedKeys = Set(doomed.map(\.uniqueKey))
        let survivors = try modelContext.fetch(
            FetchDescriptor<Message>(sortBy: [SortDescriptor(\.time, order: .reverse)])
        ).filter { !doomedKeys.contains($0.uniqueKey) }

        // Keyed on (server, topic), not the topic string alone: two servers
        // may both carry a topic named "alerts" (spec §4 models `Subscription`
        // as belonging to a `Server` for exactly this reason), and a shared
        // key would let a busy topic on one server evict a quiet one on
        // another.
        var seenPerTopic: [String: Int] = [:]
        for message in survivors {
            let key = "\(message.serverID.uuidString)/\(message.topic)"
            let count = (seenPerTopic[key] ?? 0) + 1
            seenPerTopic[key] = count
            if count > policy.maxMessagesPerTopic { doomed.append(message) }
        }

        var filesDeleted = 0
        for message in doomed {
            if let directory = attachmentsDirectory,
               let filename = message.attachment?.localFilename {
                // `localFilename` must be a bare path component. No
                // downloader writes this field yet, but the safety of a
                // `removeItem` call should not depend on every future writer
                // being careful — a guard here holds regardless of who sets
                // the field or what they intended. Reject rather than
                // sanitize: stripping "../" invites a double-encoding
                // argument, and a non-component filename is a bug in
                // whoever wrote it, not something to repair. The message is
                // past retention either way, so the row is still deleted —
                // only the file operation is declined, and it does not
                // count toward `attachmentFilesDeleted`.
                guard !filename.isEmpty,
                      !filename.contains("/"),
                      !filename.contains("\\"),
                      filename != ".", filename != ".."
                else {
                    // Never interpolate `filename` itself: it is the same
                    // server-provided value class `Log.store`'s doc comment
                    // already bars from this log line.
                    Log.store.error("refusing to delete an attachment with a non-component filename")
                    modelContext.delete(message)
                    continue
                }
                let url = directory.appendingPathComponent(filename)
                do {
                    try FileManager.default.removeItem(at: url)
                    filesDeleted += 1
                } catch CocoaError.fileNoSuchFile {
                    // Already gone: the row outlived its file. Not an error —
                    // the goal is that the file is absent, and it is.
                } catch {
                    // Not `error.localizedDescription`: Cocoa's file-removal
                    // errors embed the display name of the file they failed
                    // on, which is `Attachment.localFilename` — content that
                    // reached this device from a server-provided attachment
                    // name, the same category `Log.store`'s doc comment bars
                    // (see the topic/messageID reasoning there). Domain and
                    // code are a closed, fixed-shape vocabulary instead.
                    let nsError = error as NSError
                    Log.store.error("attachment file deletion failed: \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public)")
                }
            }
            modelContext.delete(message)
        }

        try modelContext.save()
        return PruneResult(messagesDeleted: doomed.count, attachmentFilesDeleted: filesDeleted)
    }
}
