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
        /// The events newly written by this call, in the order they arrived —
        /// the ones, and only the ones, a notifier may alert on. Duplicates
        /// and non-message lines are absent by construction, so a caller
        /// notifying from this cannot raise a second banner for a message a
        /// reconnect replayed, nor one for a keepalive.
        public let stored: [NtfyEvent]
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
        guard !messages.isEmpty else {
            return InsertResult(inserted: 0, duplicatesSkipped: 0, stored: [])
        }

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

        var stored: [NtfyEvent] = []
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
            stored.append(event)

            if newest[event.topic] == nil || event.date > newest[event.topic]! {
                newest[event.topic] = event.date
                newestID[event.topic] = event.id
            }
        }

        try advanceWatermarks(newest, ids: newestID, serverID: serverID)
        try modelContext.save()
        return InsertResult(inserted: stored.count, duplicatesSkipped: skipped, stored: stored)
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

    /// Per-topic alert settings for the decision. An absent subscription row
    /// defaults to alerting: suppressing by default would hide messages the
    /// user can find in the archive but was never told about.
    public func alertSettings(forServer serverID: UUID,
                              topic: String) throws -> TopicAlertSettings {
        guard let sub = try subscriptions(forServer: serverID)
            .first(where: { $0.topic == topic }) else {
            return TopicAlertSettings(muted: false, minAlertPriority: 1)
        }
        return TopicAlertSettings(muted: sub.muted, minAlertPriority: sub.minAlertPriority)
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

extension MessageStore {
    /// Newest first. Honours every non-nil field of the query.
    ///
    /// Every field except `tag` is folded into one `#Predicate` and pushed to
    /// SQL — the same reasoning as `messages(forServer:topic:limit:)`:
    /// applying `fetchLimit`/`fetchOffset` before a filter silently truncates
    /// or mis-pages a result. `tag` cannot join that predicate — see the
    /// comment below — so when it is set, this fetches every SQL-filtered
    /// row unpaged, filters those by tag in Swift, and only then slices by
    /// `offset`/`limit`. That ordering (tag filter strictly before
    /// pagination) is what avoids the exact truncation bug the SQL-pushed
    /// path avoids by construction.
    public func search(_ query: MessageQuery) throws -> [MessageSnapshot] {
        let serverID = query.serverID
        let topic = query.topic
        let searchText = query.searchText
        let minPriority = query.minPriority
        let unreadOnly = query.unreadOnly
        let since = query.since
        let until = query.until

        // Split into small sub-predicates composed via `.evaluate(_:)`
        // rather than one large `&&` chain: the single-expression form times
        // out the compiler's predicate type-checker. Each piece still
        // becomes part of the one `Predicate` handed to `FetchDescriptor`,
        // so this is still filtering in SQL, not post-fetch in memory.
        let scopeFilter = #Predicate<Message> { message in
            (serverID == nil || message.serverID == serverID!) &&
            (topic == nil || message.topic == topic!)
        }
        let priorityAndReadFilter = #Predicate<Message> { message in
            (minPriority == nil || message.priority >= minPriority!) &&
            (!unreadOnly || message.isRead == false)
        }
        let dateFilter = #Predicate<Message> { message in
            (since == nil || message.time >= since!) &&
            (until == nil || message.time <= until!)
        }
        let searchTextFilter = #Predicate<Message> { message in
            // `message.title!` (force-unwrapping a *model* optional, as
            // opposed to `searchText!` above, which force-unwraps a
            // captured Swift value) is rejected at runtime with
            // `unsupportedPredicate` — SwiftData's predicate translator
            // does not support `ForcedUnwrap` on a fetched property. Optional
            // chaining with `??` is supported and expresses the same thing.
            searchText == nil ||
            message.body.localizedStandardContains(searchText!) ||
            (message.title?.localizedStandardContains(searchText!) ?? false)
        }

        var descriptor = FetchDescriptor<Message>(
            predicate: #Predicate<Message> { message in
                scopeFilter.evaluate(message) &&
                priorityAndReadFilter.evaluate(message) &&
                dateFilter.evaluate(message) &&
                searchTextFilter.evaluate(message)
            },
            sortBy: [SortDescriptor(\.time, order: .reverse)])

        guard let tag = query.tag else {
            descriptor.fetchLimit = query.limit
            descriptor.fetchOffset = query.offset
            return try modelContext.fetch(descriptor).map(\.snapshot)
        }

        // `Message.tags` (`[String]`) is stored as a transformable blob, not
        // a SQL-queryable column: CoreData cannot generate SQL for
        // `Array.contains` against it at all on this platform — confirmed by
        // spiking even the plainest possible form,
        // `message.tags.contains("literal")`, with no captured variable and
        // no optional handling involved. It does not throw a catchable
        // error; it crashes the process (`NSInvalidArgumentException`,
        // "unimplemented SQL generation ... (bad LHS)"), so there is no
        // fallback-and-recover option — the filter must not reach SQL.
        let matches = try modelContext.fetch(descriptor).filter { $0.tags.contains(tag) }
        let page = matches.dropFirst(query.offset).prefix(query.limit)
        return page.map(\.snapshot)
    }

    /// One row per (server, topic) that has a `Subscription`, for the
    /// sidebar's unread badges.
    public func topicSummaries() throws -> [TopicSummary] {
        let servers = try modelContext.fetch(
            FetchDescriptor<Server>(sortBy: [SortDescriptor(\.sortOrder)]))

        var summaries: [TopicSummary] = []
        for server in servers {
            let serverID = server.id
            for sub in server.subscriptions {
                let topic = sub.topic
                let total = try modelContext.fetchCount(FetchDescriptor<Message>(
                    predicate: #Predicate { $0.serverID == serverID && $0.topic == topic }))
                let unread = try modelContext.fetchCount(FetchDescriptor<Message>(
                    predicate: #Predicate {
                        $0.serverID == serverID && $0.topic == topic && $0.isRead == false
                    }))
                summaries.append(TopicSummary(
                    serverID: serverID, topic: topic, displayName: sub.displayName,
                    unreadCount: unread, totalCount: total, lastMessageTime: sub.lastMessageTime,
                    muted: sub.muted, minAlertPriority: sub.minAlertPriority))
            }
        }
        return summaries
    }

    /// Count of unread messages, optionally scoped to a server and/or topic.
    public func unreadCount(serverID: UUID?, topic: String?) throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<Message>(
            predicate: #Predicate<Message> { message in
                (serverID == nil || message.serverID == serverID!) &&
                (topic == nil || message.topic == topic!) &&
                message.isRead == false
            }))
    }

    /// Sets `isRead` on exactly the rows named by `uniqueKeys`. Keys with no
    /// matching row are silently ignored — a row deleted (by prune, or by a
    /// concurrent `deleteMessages` call) between the caller reading it and
    /// this call is not an error, just nothing left to mark.
    public func markRead(_ uniqueKeys: [String], read: Bool) throws {
        guard !uniqueKeys.isEmpty else { return }
        let keys = Set(uniqueKeys)
        let messages = try modelContext.fetch(
            FetchDescriptor<Message>(predicate: #Predicate { keys.contains($0.uniqueKey) }))
        for message in messages { message.isRead = read }
        try modelContext.save()
    }

    /// Marks every currently-unread message in scope as read.
    public func markAllRead(serverID: UUID?, topic: String?) throws {
        let messages = try modelContext.fetch(FetchDescriptor<Message>(
            predicate: #Predicate<Message> { message in
                (serverID == nil || message.serverID == serverID!) &&
                (topic == nil || message.topic == topic!) &&
                message.isRead == false
            }))
        guard !messages.isEmpty else { return }
        for message in messages { message.isRead = true }
        try modelContext.save()
    }

    /// Deletes exactly the rows named by `uniqueKeys`. `Message.attachment`
    /// cascades (`deleteRule: .cascade` in `Models.swift`), so its
    /// `Attachment` row goes with it — but the attachment's downloaded FILE
    /// does not, the same as everywhere else in this actor that deletes a
    /// `Message` outside of `prune`: only `prune` is handed an
    /// `attachmentsDirectory` to reconcile disk with rows.
    public func deleteMessages(_ uniqueKeys: [String]) throws {
        guard !uniqueKeys.isEmpty else { return }
        let keys = Set(uniqueKeys)
        let messages = try modelContext.fetch(
            FetchDescriptor<Message>(predicate: #Predicate { keys.contains($0.uniqueKey) }))
        for message in messages { modelContext.delete(message) }
        try modelContext.save()
    }

    /// Adds a server and returns its id. Credentials go to the Keychain by
    /// the caller, never here.
    public func addServer(name: String, baseURL: URL, authKindRaw: String) throws -> UUID {
        var top = FetchDescriptor<Server>(sortBy: [SortDescriptor(\.sortOrder, order: .reverse)])
        top.fetchLimit = 1
        let nextSortOrder = (try modelContext.fetch(top).first?.sortOrder ?? -1) + 1

        let server = Server(name: name, baseURLString: baseURL.absoluteString,
                            authKindRaw: authKindRaw, sortOrder: nextSortOrder)
        modelContext.insert(server)
        try modelContext.save()
        return server.id
    }

    /// Removes a server, its subscriptions, and its message history.
    ///
    /// `Message.serverID` is a plain value, not a relationship, so the
    /// cascade delete on `Server.subscriptions` does not reach messages —
    /// they must be deleted explicitly here or they are orphaned forever.
    /// `Attachment` still cascades from `Message` (see `deleteMessages`), so
    /// no separate attachment query is needed.
    public func removeServer(_ serverID: UUID) throws {
        guard let server = try server(serverID) else {
            // An unknown server id is a caller bug, the same as every other
            // server-scoped method in this actor — nothing to remove.
            Log.store.error("no server record for the requested id")
            return
        }
        let messages = try modelContext.fetch(
            FetchDescriptor<Message>(predicate: #Predicate { $0.serverID == serverID }))
        for message in messages { modelContext.delete(message) }
        modelContext.delete(server)
        try modelContext.save()
    }

    /// Subscribes `serverID` to `topic`. A topic already subscribed is left
    /// untouched — a no-op, not a duplicate `Subscription` row, which would
    /// otherwise make every `first(where:)` lookup in this actor pick
    /// whichever row happens to come back first.
    public func addTopic(_ topic: String, toServer serverID: UUID) throws {
        guard let server = try server(serverID) else {
            Log.store.error("no server record for the requested id")
            return
        }
        guard !server.subscriptions.contains(where: { $0.topic == topic }) else { return }

        modelContext.insert(Subscription(topic: topic, server: server))
        // §5.2: `caughtUpTo` means "delivered on every subscribed topic",
        // which was never true of this one — leaving it set would skip
        // anything the new topic published before the old resume point.
        server.caughtUpTo = nil
        try modelContext.save()
    }

    /// Unsubscribes `serverID` from `topic`. Message history for the topic
    /// is left in place — only `removeServer` purges history, and only
    /// because the server itself is gone.
    public func removeTopic(_ topic: String, fromServer serverID: UUID) throws {
        guard let server = try server(serverID) else {
            Log.store.error("no server record for the requested id")
            return
        }
        guard let subscription = server.subscriptions.first(where: { $0.topic == topic }) else {
            return
        }
        modelContext.delete(subscription)
        try modelContext.save()
    }

    /// Writes per-topic alert settings to the `Subscription` row.
    public func setAlertSettings(_ settings: TopicAlertSettings,
                                 forServer serverID: UUID, topic: String) throws {
        guard let server = try server(serverID) else {
            Log.store.error("no server record for the requested id")
            return
        }
        guard let subscription = server.subscriptions.first(where: { $0.topic == topic }) else {
            // No subscription row for this topic — the same "caller bug,
            // nowhere to store it" case as `alertSettings`'s counterpart.
            Log.store.error("no subscription record for the requested topic")
            return
        }
        subscription.muted = settings.muted
        subscription.minAlertPriority = settings.minAlertPriority
        try modelContext.save()
    }
}
