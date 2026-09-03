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
            // `includePendingChanges` (default `true`) is not needed here —
            // within this call, a message is only ever inserted into
            // `modelContext` *after* this loop finishes, and across calls a
            // successful `insert` always `save()`s before returning, so
            // anything genuinely a duplicate is already committed and
            // visible regardless of this flag. Turning it off matters for a
            // different reason: after a call whose `save()` threw and was
            // rolled back, `includePendingChanges: true` can still report a
            // row that is in neither the context's pending-changes set
            // (confirmed empirically: `rollback()` leaves `hasChanges ==
            // false` and an empty `insertedModelsArray`) nor the persisted
            // store (confirmed against a second, independent connection to
            // the same file) — a `FetchDescriptor` defect, not a `rollback()`
            // failure, that otherwise reintroduces this exact bug on retry.
            descriptor.includePendingChanges = false
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
                actionsJSON: event.actions.flatMap { try? JSONEncoder().encode($0) },
                // `urlString` is stored verbatim, unparsed and unvalidated —
                // it is attacker-controlled wire content (spec §9), and the
                // only code that ever acts on it, `AttachmentDownloader`,
                // does its own scheme allow-listing and sanitizing at the
                // point of use. `localFilename` starts `nil`: nothing has
                // downloaded anything yet at insert time, so there is no
                // local file to name. It is filled in later, if ever, by
                // `setAttachmentLocalFilename` once a download succeeds.
                attachment: event.attachment.map {
                    Attachment(name: $0.name, urlString: $0.url, type: $0.type, size: $0.size,
                              expires: $0.expires.map { Date(timeIntervalSince1970: TimeInterval($0)) })
                }
            ))
            stored.append(event)

            if newest[event.topic] == nil || event.date > newest[event.topic]! {
                newest[event.topic] = event.date
                newestID[event.topic] = event.id
            }
        }

        do {
            try advanceWatermarks(newest, ids: newestID, serverID: serverID)
            try modelContext.save()
        } catch {
            // A thrown `advanceWatermarks` or `save()` leaves the `Message`
            // objects just inserted above — and any watermark mutation
            // `advanceWatermarks` already made — sitting in `modelContext`
            // as uncommitted pending changes; nothing here rolls them back
            // on its own. Left there, `Ingest.Buffer` requeues this same
            // batch and retries it unchanged on the next tick, and that
            // retry's own duplicate-detection fetch would see them and
            // classify every event as an existing duplicate — the messages
            // eventually land in the database (the retry's `save()` succeeds
            // once the transient failure clears) but `stored` comes back
            // empty, so the notification hook that reads it never fires: a
            // silent loss of the exact signal this app exists to deliver.
            //
            // `rollback()` does clean the object graph — verified
            // empirically, `hasChanges` is `false` and `insertedModelsArray`
            // is empty immediately after. It is NOT, by itself, what closes
            // the hole above: a `FetchDescriptor` with the default
            // `includePendingChanges: true`, run on this SAME context right
            // after, can still report one of these rows as existing even
            // though it is in neither the (now-empty) pending-changes set
            // nor the persisted store — confirmed against a second,
            // independent connection to the same file. That is what the
            // existence-check fetch above turns off explicitly; `rollback()`
            // here is still correct and still needed (it undoes the
            // watermark mutations too), just not sufficient on its own.
            modelContext.rollback()
            throw error
        }
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
            do {
                try modelContext.save()
            } catch {
                // Same shape as `addTopic`'s `caughtUpTo = nil`: a failed
                // save must not leave this mutation sitting uncommitted,
                // or an unrelated later `save()` could commit a resume
                // point the caller was told did not persist.
                modelContext.rollback()
                throw error
            }
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

    /// Fetches one message by its `uniqueKey`, or `nil` if no such row
    /// exists — pruned by retention between whoever captured the key and
    /// this call, or the key never matched a message at all. An indexed
    /// lookup on `uniqueKey`'s `.unique` attribute (`Models.swift`), the
    /// same pattern `setAttachmentLocalFilename` uses, not a table scan —
    /// this is the resolve step behind "open this message" from a stored
    /// key (a notification click, or a menu bar popover tap).
    public func message(uniqueKey: String) throws -> MessageSnapshot? {
        var descriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.uniqueKey == uniqueKey })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.snapshot
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

        // One-time migration for rows written before `tagsJoined` existed:
        // `search`'s tag filter matches `tagsJoined`, not `tags`, and a
        // stale (or default-empty) `tagsJoined` is not otherwise
        // repairable — there is no query that can find "rows whose
        // `tagsJoined` needs recomputing" using `tagsJoined` itself. This
        // piggybacks on `prune`'s already-scheduled full-table scan (spec
        // §8: launch and daily) instead of a bespoke migration pass; a
        // message about to be deleted below gets recomputed too, which is
        // wasted but harmless. The comparison keeps this cheap for the
        // overwhelming majority of rows, which already match.
        for message in survivors {
            let expected = Message.joinTags(message.tags)
            if message.tagsJoined != expected {
                message.tagsJoined = expected
            }
        }

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

        // Capture filenames before deleting the rows, and delete files only
        // after the row deletion is durably saved — see
        // `deleteAttachmentFile`'s doc comment for why the ordering matters:
        // deleting a file before the row that owned it is committed risks a
        // failed `save()` leaving the file gone but the row still pending,
        // later committed silently by an unrelated `save()`.
        let doomedAttachmentFilenames = doomed.map { $0.attachment?.localFilename }
        for message in doomed {
            modelContext.delete(message)
        }
        do {
            try modelContext.save()
        } catch {
            // Same reasoning as `insert`'s catch: leaving `doomed`'s pending
            // deletions (and the `tagsJoined` migration above) sitting
            // uncommitted risks them being silently committed later by an
            // unrelated `save()`, at which point neither this call's
            // `throw` nor its (never returned) `PruneResult` reflected what
            // actually happened.
            modelContext.rollback()
            throw error
        }

        var filesDeleted = 0
        for filename in doomedAttachmentFilenames {
            if deleteAttachmentFile(named: filename, in: attachmentsDirectory) {
                filesDeleted += 1
            }
        }
        return PruneResult(messagesDeleted: doomed.count, attachmentFilesDeleted: filesDeleted)
    }

    /// Deletes the attachment file named `filename` from `directory`, if
    /// both are given. Returns whether a file was actually removed, for
    /// callers (`prune`) that count it. Shared by `prune` and
    /// `deleteMessages` so the path-traversal guard on `localFilename` — a
    /// real fix, not defensive boilerplate — exists in exactly one place
    /// rather than being re-derived, and potentially re-broken, at each
    /// call site.
    ///
    /// Takes the filename directly rather than a `Message`, and is always
    /// called strictly *after* the row deletion that made the file
    /// obsolete has already been durably `save()`d — never before. Both
    /// callers capture `message.attachment?.localFilename` before deleting
    /// the row precisely so this ordering is possible: deleting the file
    /// first and the row second would mean a failed `save()` leaves the
    /// file gone, the row still present-but-pending-deleted, and the
    /// caller told the delete failed — until an unrelated later `save()`
    /// (from any other method) commits the row deletion nobody was told
    /// succeeded.
    private func deleteAttachmentFile(named filename: String?, in directory: URL?) -> Bool {
        guard let directory, let filename else { return false }
        // `localFilename` must be a bare path component. No downloader wrote
        // this field when this guard was first added, but the safety of a
        // `removeItem` call should not depend on every future writer being
        // careful — this guard holds regardless of who sets the field or
        // what they intended. Reject rather than sanitize: stripping "../"
        // invites a double-encoding argument, and a non-component filename
        // is a bug in whoever wrote it, not something to repair. The caller
        // still deletes the message row either way — only the file
        // operation is declined here.
        guard !filename.isEmpty,
              !filename.contains("/"),
              !filename.contains("\\"),
              filename != ".", filename != ".."
        else {
            // Never interpolate `filename` itself: it is the same
            // server-provided value class `Log.store`'s doc comment already
            // bars from this log line.
            Log.store.error("refusing to delete an attachment with a non-component filename")
            return false
        }
        let url = directory.appendingPathComponent(filename)
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch CocoaError.fileNoSuchFile {
            // Already gone: the row outlived its file. Not an error — the
            // goal is that the file is absent, and it is.
            return false
        } catch {
            // Not `error.localizedDescription`: Cocoa's file-removal errors
            // embed the display name of the file they failed on, which is
            // `Attachment.localFilename` — content that reached this device
            // from a server-provided attachment name, the same category
            // `Log.store`'s doc comment bars (see the topic/messageID
            // reasoning there). Domain and code are a closed, fixed-shape
            // vocabulary instead.
            let nsError = error as NSError
            Log.store.error("attachment file deletion failed: \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public)")
            return false
        }
    }
}

extension MessageStore {
    /// Newest first. Honours every non-nil field of the query.
    ///
    /// Every field is folded into one `#Predicate` and pushed to SQL — the
    /// same reasoning as `messages(forServer:topic:limit:)`: applying
    /// `fetchLimit`/`fetchOffset` before a filter silently truncates or
    /// mis-pages a result. `tag` matches against `Message.tagsJoined`, the
    /// denormalized form of `tags` — never `tags` itself. `Message.tags`
    /// (`[String]`) is stored as a transformable blob, not a SQL-queryable
    /// column: CoreData cannot generate SQL for `Array.contains` against it
    /// at all on this platform — confirmed by spiking even the plainest
    /// possible form, `message.tags.contains("literal")`, with no captured
    /// variable and no optional handling involved. It does not throw a
    /// catchable error; it crashes the process
    /// (`NSInvalidArgumentException`, "unimplemented SQL generation ... (bad
    /// LHS)"). `tagsJoined.contains(...)` is a plain `String.contains`
    /// predicate — the same shape `searchText` already pushes to SQL
    /// successfully — so this needs no in-memory fallback and no
    /// unpaged fetch: `tag` pages exactly like every other filter.
    public func search(_ query: MessageQuery) throws -> [MessageSnapshot] {
        let serverID = query.serverID
        let topic = query.topic
        let searchText = query.searchText
        let minPriority = query.minPriority
        let unreadOnly = query.unreadOnly
        let since = query.since
        let until = query.until
        // See `Message.joinTags`'s doc comment for why both delimiters are
        // required: `"|alert|"` must not match inside `"|alerts|"`. A tag
        // containing `"|"` never appears in a real `tagsJoined` value (that
        // tag is dropped when `tagsJoined` is built), so searching for one
        // here simply matches nothing rather than something unintended.
        let tagMatch = query.tag.map { "|\($0)|" }

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
        let tagFilter = #Predicate<Message> { message in
            tagMatch == nil || message.tagsJoined.contains(tagMatch!)
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
                tagFilter.evaluate(message) &&
                searchTextFilter.evaluate(message)
            },
            sortBy: [SortDescriptor(\.time, order: .reverse)])
        descriptor.fetchLimit = query.limit
        descriptor.fetchOffset = query.offset
        return try modelContext.fetch(descriptor).map(\.snapshot)
    }

    /// One row per (server, topic) that has a `Subscription`, for the
    /// sidebar's unread badges. Ordered by server `sortOrder`, then topic
    /// name — `server.subscriptions` is a SwiftData to-many relationship
    /// with no defined order, and a sidebar `List` reshuffling rows between
    /// refreshes would be worse than an arbitrary-but-stable one.
    public func topicSummaries() throws -> [TopicSummary] {
        let servers = try modelContext.fetch(
            FetchDescriptor<Server>(sortBy: [SortDescriptor(\.sortOrder)]))

        var summaries: [TopicSummary] = []
        for server in servers {
            let serverID = server.id
            for sub in server.subscriptions.sorted(by: { $0.topic < $1.topic }) {
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
        do {
            try modelContext.save()
        } catch {
            // Same reasoning as `insert`'s catch: a failed save must not
            // leave these `isRead` flips sitting uncommitted, or an
            // unrelated later `save()` could commit a read/unread state
            // the caller was told did not persist.
            modelContext.rollback()
            throw error
        }
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
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    /// Records `filename` as the attachment's downloaded local file, once
    /// `AttachmentDownloader.download` has actually written it to disk. A
    /// no-op — not an error — when the message is gone or never had an
    /// attachment: either means a download raced a concurrent deletion or
    /// edit, not a caller bug, and there is nowhere left to record the
    /// result.
    public func setAttachmentLocalFilename(_ filename: String, forMessage uniqueKey: String) throws {
        var descriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.uniqueKey == uniqueKey })
        descriptor.fetchLimit = 1
        guard let attachment = try modelContext.fetch(descriptor).first?.attachment else { return }
        attachment.localFilename = filename
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    /// Deletes exactly the rows named by `uniqueKeys`. `Message.attachment`
    /// cascades (`deleteRule: .cascade` in `Models.swift`), so its
    /// `Attachment` row goes with it — and, when `attachmentsDirectory` is
    /// given, its downloaded FILE goes too, via the same guarded deletion
    /// `prune` uses (see `deleteAttachmentFile`). No default: both of this
    /// project's app-layer call sites once omitted this parameter, silently
    /// never deleting a single downloaded file no matter how many messages
    /// were deleted — the parameter must be impossible to forget, not
    /// merely possible to pass. Pass `nil` explicitly for tests and for a
    /// build with no downloader.
    ///
    /// Attachment filenames are captured before the rows are deleted, and
    /// the files themselves are only removed *after* `save()` durably
    /// commits the row deletions — never before. Deleting a file first
    /// would mean a failed `save()` leaves the file gone, the row still
    /// present-but-pending-deleted, and the caller told the delete failed
    /// — until an unrelated later `save()` (from any other method) commits
    /// a deletion nobody was told succeeded. That is data loss the caller
    /// has no way to detect, not just a stale read.
    public func deleteMessages(_ uniqueKeys: [String], attachmentsDirectory: URL?) throws {
        guard !uniqueKeys.isEmpty else { return }
        let keys = Set(uniqueKeys)
        let messages = try modelContext.fetch(
            FetchDescriptor<Message>(predicate: #Predicate { keys.contains($0.uniqueKey) }))
        let attachmentFilenames = messages.map { $0.attachment?.localFilename }
        for message in messages {
            modelContext.delete(message)
        }
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }

        guard attachmentsDirectory != nil else { return }
        for filename in attachmentFilenames {
            _ = deleteAttachmentFile(named: filename, in: attachmentsDirectory)
        }
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
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
        return server.id
    }

    /// Removes a server, its subscriptions, and its message history.
    ///
    /// `Message.serverID` is a plain value, not a relationship, so the
    /// cascade delete on `Server.subscriptions` does not reach messages —
    /// they must be deleted explicitly here or they are orphaned forever.
    /// `Attachment` still cascades from `Message` at the row level, but a
    /// row's cascade deletion does not touch the downloaded FILE it named —
    /// `attachmentsDirectory`, when given, is what actually removes those,
    /// via the same guarded deletion `prune` and `deleteMessages` use (see
    /// `deleteAttachmentFile`). No default: a server removal that silently
    /// skipped file cleanup because a caller forgot the parameter would
    /// orphan every downloaded file with no row left to name it, forever —
    /// a caller must decide, not fall into `nil` by omission. Pass `nil`
    /// explicitly for tests and for a build with no downloader.
    ///
    /// Deliberately asymmetric with `removeTopic`, which keeps history: a
    /// removed server's messages would otherwise be unreachable forever —
    /// no `serverID` remains to scope a `search`/`messages` call to them,
    /// and no UI could show them — so keeping the rows would only be
    /// keeping dead weight. A topic removed from a server that still exists
    /// has no such problem; its messages stay reachable through that
    /// server, which is exactly why `removeTopic` leaves them alone.
    public func removeServer(_ serverID: UUID, attachmentsDirectory: URL?) throws {
        guard let server = try server(serverID) else {
            // An unknown server id is a caller bug, the same as every other
            // server-scoped method in this actor — nothing to remove.
            Log.store.error("no server record for the requested id")
            return
        }
        let messages = try modelContext.fetch(
            FetchDescriptor<Message>(predicate: #Predicate { $0.serverID == serverID }))
        // Captured before the rows are deleted, and the files themselves
        // removed only after `save()` durably commits — see
        // `deleteMessages`'s doc comment for why the ordering matters: a
        // file deleted before its row's deletion is committed risks a
        // failed `save()` leaving the file gone but the row still present,
        // later silently finished off by an unrelated `save()`.
        let attachmentFilenames = messages.map { $0.attachment?.localFilename }
        for message in messages { modelContext.delete(message) }
        modelContext.delete(server)
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }

        guard attachmentsDirectory != nil else { return }
        for filename in attachmentFilenames {
            _ = deleteAttachmentFile(named: filename, in: attachmentsDirectory)
        }
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
        do {
            try modelContext.save()
        } catch {
            // A failed save must not leave the new `Subscription` or the
            // `caughtUpTo = nil` mutation sitting uncommitted — an
            // unrelated later `save()` (e.g. from `insert`) could commit
            // `caughtUpTo = nil` alone, silently forcing a full-cache
            // replay for a topic the caller was told was never added.
            modelContext.rollback()
            throw error
        }
    }

    /// Unsubscribes `serverID` from `topic`. Message history for the topic
    /// is deliberately left in place: unsubscribing should not destroy the
    /// archive of what the topic already sent, and unlike `removeServer`,
    /// the server still exists, so those messages stay reachable through it
    /// — nothing here would orphan them the way `removeServer` would leave
    /// `Message.serverID` rows behind pointing at a `Server` that is gone.
    /// Only `removeServer` purges history, and only because the server
    /// itself is gone.
    public func removeTopic(_ topic: String, fromServer serverID: UUID) throws {
        guard let server = try server(serverID) else {
            Log.store.error("no server record for the requested id")
            return
        }
        guard let subscription = server.subscriptions.first(where: { $0.topic == topic }) else {
            return
        }
        modelContext.delete(subscription)
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    /// Writes per-topic alert settings to the `Subscription` row.
    public func setAlertSettings(_ settings: TopicAlertSettings,
                                 forServer serverID: UUID, topic: String) throws {        guard let server = try server(serverID) else {
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
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
    }
}
