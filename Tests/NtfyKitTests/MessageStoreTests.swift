import Foundation
import SwiftData
#if canImport(Darwin)
import Darwin
#endif
import Testing
@testable import NtfyKit

private func event(_ id: String, topic: String = "alerts", time: Int, body: String) -> NtfyEvent {
    let json = """
    {"id":"\(id)","time":\(time),"event":"message","topic":"\(topic)","message":"\(body)"}
    """
    return try! JSONDecoder().decode(NtfyEvent.self, from: Data(json.utf8))
}

private func makeStore() throws -> (MessageStore, UUID) {
    let container = try StoreFixtures.inMemoryContainer()
    let serverID = UUID()
    let context = ModelContext(container)
    let server = Server(id: serverID, name: "Example",
                        baseURLString: "https://ntfy.example.com")
    context.insert(server)
    context.insert(Subscription(topic: "alerts", server: server))
    try context.save()
    return (MessageStore(modelContainer: container), serverID)
}

@Test func insertingMessagesPersistsThem() async throws {
    let (store, serverID) = try makeStore()
    let result = try await store.insert(
        [event("a", time: 100, body: "one"), event("b", time: 200, body: "two")],
        serverID: serverID)
    #expect(result.inserted == 2)
    #expect(result.duplicatesSkipped == 0)
    #expect(try await store.messageCount() == 2)
}

/// The invariant the whole reconnect design rests on: an overlapping replay
/// window must **skip** the rows it already holds, not duplicate them and not
/// overwrite them. (An earlier version of this comment said "upsert", which is
/// the opposite of what the code does and of what
/// `replayingDoesNotResetIsReadToFalse` below depends on.)
@Test func replayingAnOverlappingWindowDoesNotDuplicateRows() async throws {
    let (store, serverID) = try makeStore()
    _ = try await store.insert([event("a", time: 100, body: "one"),
                                event("b", time: 200, body: "two")], serverID: serverID)
    let second = try await store.insert([event("b", time: 200, body: "two"),
                                         event("c", time: 300, body: "three")], serverID: serverID)
    #expect(second.inserted == 1)
    #expect(second.duplicatesSkipped == 1)
    #expect(try await store.messageCount() == 3)
}

/// A thrown `save()` must not leave the just-inserted `Message` objects
/// pending in the context. If it did, `Ingest.Buffer`'s retry of the same
/// batch would run its duplicate-detection fetch against a context that
/// already contains them (`FetchDescriptor.includePendingChanges` defaults
/// to `true`), classify every event as an existing duplicate, and report an
/// empty `stored` — so the messages would still end up saved once the
/// retry's own `save()` succeeds, but the notification hook that reads
/// `stored` would never fire for them. That is a silent loss of exactly the
/// signal this app exists to deliver.
///
/// This needs a `save()` that genuinely throws, not a mock: the project has
/// twice declined to add a `MessageWriting` seam for exactly this kind of
/// injection, so there is no protocol to substitute here. Two techniques
/// were tried and rejected before this one:
/// - Revoking POSIX write permission on an on-disk store's files/directory
///   *after* opening them once: permission bits are checked at `open(2)`
///   time only, so a write through the already-open connection still
///   succeeds — no failure is produced at all.
/// - Opening a *fresh* connection to that now-permission-revoked store: this
///   does make `save()` throw, but SwiftData bakes
///   `NSReadOnlyPersistentStoreOption` into that connection at open time —
///   restoring the file permissions afterward does not un-set it, so a
///   retry on the *same* store keeps behaving as a permanently read-only
///   store rather than as a transient failure that cleared. Empirically,
///   under that condition `rollback()` does not make the pending insert
///   disappear from a subsequent `includePendingChanges` fetch either — an
///   artifact of the technique, not evidence about the fix, since a
///   deliberately-never-saved insert *does* correctly disappear after
///   `rollback()` on a normal writable context (verified separately).
/// `RLIMIT_FSIZE` avoids both problems: it caps how large a file this
/// process may write to *right now*, checked on every `write(2)`, and never
/// touches how the store itself is configured — the connection stays a
/// completely ordinary read-write one throughout, so restoring the limit
/// affects the very next write, not a cached decision from `open(2)` time.
/// `SIGXFSZ` is ignored first because exceeding the limit sends that signal
/// by default, which would kill the test process outright instead of
/// letting the `write(2)` call return `EFBIG` for SQLite to surface as a
/// normal thrown error.
@Test func aFailedSaveRollsBackSoARetriedBatchIsNotMistakenForADuplicate() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MessageStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let storeURL = directory.appendingPathComponent("store.sqlite")
    let serverID = UUID()
    let container = try ModelContainer(
        for: Message.self, Subscription.self, Server.self, Attachment.self,
        configurations: ModelConfiguration(url: storeURL))
    let setupContext = ModelContext(container)
    let server = Server(id: serverID, name: "Example", baseURLString: "https://ntfy.example.com")
    setupContext.insert(server)
    setupContext.insert(Subscription(topic: "alerts", server: server))
    try setupContext.save()   // Creates the on-disk files at their baseline size.

    let previousXFSZHandler = signal(SIGXFSZ, SIG_IGN)
    var originalLimit = rlimit()
    getrlimit(RLIMIT_FSIZE, &originalLimit)
    defer {
        setrlimit(RLIMIT_FSIZE, &originalLimit)
        signal(SIGXFSZ, previousXFSZHandler)
    }

    let store = MessageStore(modelContainer: container)
    let batch = [event("a", time: 100, body: "one")]

    // Cap file growth at the baseline size reached above — the very next
    // write that would grow the store fails with EFBIG.
    let baselineFiles = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    let baselineSize = try baselineFiles
        .map { try FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int ?? 0 }
        .max() ?? 0
    var tightLimit = rlimit()
    tightLimit.rlim_cur = rlim_t(baselineSize)
    tightLimit.rlim_max = originalLimit.rlim_max
    #expect(setrlimit(RLIMIT_FSIZE, &tightLimit) == 0)

    await #expect(throws: (any Error).self) {
        try await store.insert(batch, serverID: serverID)
    }

    // Lift the cap — mirroring however a real transient I/O failure would
    // clear — and retry the SAME batch, unchanged, on the SAME store (same
    // actor, same `modelContext`), exactly as `Ingest.Buffer` does after a
    // failed flush.
    #expect(setrlimit(RLIMIT_FSIZE, &originalLimit) == 0)

    let retry = try await store.insert(batch, serverID: serverID)
    #expect(retry.stored.map(\.id) == ["a"])
    #expect(retry.duplicatesSkipped == 0)
    #expect(try await store.messageCount() == 1)
}

/// Same message id on two different topics is two different messages.
///
/// Subscribes to both topics, not just `alerts` — the store's contract is
/// that a `Subscription` row exists before messages for a topic arrive
/// (`advanceWatermarks` logs an error otherwise); this test's job is to
/// prove the dedupe key, not to exercise that error path incidentally.
@Test func theSameMessageIdOnDifferentTopicsIsNotADuplicate() async throws {
    let container = try StoreFixtures.inMemoryContainer()
    let serverID = UUID()
    let context = ModelContext(container)
    let server = Server(id: serverID, name: "Example",
                        baseURLString: "https://ntfy.example.com")
    context.insert(server)
    context.insert(Subscription(topic: "alerts", server: server))
    context.insert(Subscription(topic: "deploys", server: server))
    try context.save()
    let store = MessageStore(modelContainer: container)

    let result = try await store.insert(
        [event("same", topic: "alerts", time: 100, body: "a"),
         event("same", topic: "deploys", time: 100, body: "b")], serverID: serverID)
    #expect(result.inserted == 2)
    #expect(try await store.messageCount() == 2)
}

@Test func insertingAdvancesTheTopicWatermark() async throws {
    let (store, serverID) = try makeStore()
    _ = try await store.insert([event("a", time: 100, body: "one"),
                                event("b", time: 300, body: "two"),
                                event("c", time: 200, body: "three")], serverID: serverID)
    let marks = try await store.watermarks(forServer: serverID)
    #expect(marks.count == 1)
    #expect(marks.first?.topic == "alerts")
    // Newest wins regardless of arrival order.
    #expect(marks.first?.lastMessageTime == Date(timeIntervalSince1970: 300))
}

/// An out-of-order late arrival must not move the watermark backwards.
@Test func anOlderMessageDoesNotRewindTheWatermark() async throws {
    let (store, serverID) = try makeStore()
    _ = try await store.insert([event("b", time: 300, body: "new")], serverID: serverID)
    _ = try await store.insert([event("a", time: 100, body: "old")], serverID: serverID)
    let marks = try await store.watermarks(forServer: serverID)
    #expect(marks.first?.lastMessageTime == Date(timeIntervalSince1970: 300))
}

@Test func caughtUpToRoundTrips() async throws {
    let (store, serverID) = try makeStore()
    #expect(try await store.caughtUpTo(forServer: serverID) == nil)
    let t = Date(timeIntervalSince1970: 1_788_353_322)
    try await store.setCaughtUpTo(t, forServer: serverID)
    #expect(try await store.caughtUpTo(forServer: serverID) == t)

    // The monotonic guard, which a round trip alone does not exercise: a
    // regression to last-write-wins passes every assertion above. An older
    // value must be refused, or a late flush from a superseded connection
    // could rewind the resume point and replay everything after it.
    try await store.setCaughtUpTo(t.addingTimeInterval(-3600), forServer: serverID)
    #expect(try await store.caughtUpTo(forServer: serverID) == t)
    try await store.setCaughtUpTo(t.addingTimeInterval(60), forServer: serverID)
    #expect(try await store.caughtUpTo(forServer: serverID) == t.addingTimeInterval(60))
}

/// The topic filter has to live IN the `#Predicate`, not be applied to the
/// rows a `fetchLimit` already truncated. A `#Predicate` with two captured
/// values and `&&` compiles fine and fails at *runtime*, so this branch had no
/// coverage at all despite looking obviously correct.
///
/// The two topics are interleaved in time and the limit is smaller than the
/// number of matching rows, which is the only shape that tells the two
/// implementations apart: filtering after the fetch would take the two newest
/// rows overall — one of them a `deploys` row — and return a single `alerts`
/// message for a page that asked for two.
@Test func aTopicFilteredPageIsFilteredBeforeTheLimit() async throws {
    let container = try StoreFixtures.inMemoryContainer()
    let serverID = UUID()
    let context = ModelContext(container)
    let server = Server(id: serverID, name: "Example",
                        baseURLString: "https://ntfy.example.com")
    context.insert(server)
    context.insert(Subscription(topic: "alerts", server: server))
    context.insert(Subscription(topic: "deploys", server: server))
    try context.save()
    let store = MessageStore(modelContainer: container)

    _ = try await store.insert([
        event("a1", topic: "alerts", time: 100, body: "alerts-oldest"),
        event("d1", topic: "deploys", time: 200, body: "deploys-old"),
        event("a2", topic: "alerts", time: 300, body: "alerts-middle"),
        event("d2", topic: "deploys", time: 400, body: "deploys-mid"),
        event("a3", topic: "alerts", time: 500, body: "alerts-newest"),
        event("d3", topic: "deploys", time: 600, body: "deploys-newest"),
    ], serverID: serverID)

    let page = try await store.messages(forServer: serverID, topic: "alerts", limit: 2)
    #expect(page.map(\.body) == ["alerts-newest", "alerts-middle"])

    // And the unfiltered branch still sees everything, so the assertion above
    // is about the predicate rather than about the rows that exist.
    let all = try await store.messages(forServer: serverID, topic: nil, limit: 2)
    #expect(all.map(\.body) == ["deploys-newest", "alerts-newest"])
}

@Test func messagesComeBackNewestFirst() async throws {
    let (store, serverID) = try makeStore()
    _ = try await store.insert([event("a", time: 100, body: "old"),
                                event("c", time: 300, body: "new"),
                                event("b", time: 200, body: "mid")], serverID: serverID)
    let page = try await store.messages(forServer: serverID, topic: nil, limit: 10)
    #expect(page.map(\.body) == ["new", "mid", "old"])
}

/// Non-message events carry no content and must not become rows.
@Test func keepaliveAndOpenEventsAreNotStored() async throws {
    let (store, serverID) = try makeStore()
    let open = try Fixtures.decode(Fixtures.openEvent)
    let keepalive = try Fixtures.decode(Fixtures.keepaliveEvent)
    let result = try await store.insert([open, keepalive], serverID: serverID)
    #expect(result.inserted == 0)
    #expect(try await store.messageCount() == 0)
}

/// This is the entire reason the skip exists (not the brief's 8 tests —
/// added here because none of them exercise it): `Message.isRead` is local
/// state the server knows nothing about, and every reconnect deliberately
/// re-requests an overlapping window. If a replay ever overwrote the stored
/// row, marking a message read would be undone on the next reconnect.
@Test func replayingDoesNotResetIsReadToFalse() async throws {
    let container = try StoreFixtures.inMemoryContainer()
    let serverID = UUID()
    let context = ModelContext(container)
    let server = Server(id: serverID, name: "Example",
                        baseURLString: "https://ntfy.example.com")
    context.insert(server)
    context.insert(Subscription(topic: "alerts", server: server))
    try context.save()
    let store = MessageStore(modelContainer: container)

    _ = try await store.insert([event("a", time: 100, body: "one")], serverID: serverID)

    // Mark it read directly against the same container, the way a future
    // mark-read API would.
    let stored = try context.fetch(FetchDescriptor<Message>()).first
    #expect(stored != nil)
    stored?.isRead = true
    try context.save()

    // Reconnect replays the same window.
    _ = try await store.insert([event("a", time: 100, body: "one")], serverID: serverID)

    let page = try await store.messages(forServer: serverID, topic: nil, limit: 10)
    #expect(page.first?.isRead == true)
}

@Test func alertSettingsComeFromTheSubscriptionRow() async throws {
    let container = try StoreFixtures.inMemoryContainer()
    let id = UUID()
    let context = ModelContext(container)
    let server = Server(id: id, name: "Alpha", baseURLString: "https://a.example.com")
    context.insert(server)
    context.insert(Subscription(topic: "alerts", server: server,
                                muted: true, minAlertPriority: 4))
    try context.save()

    let store = MessageStore(modelContainer: container)
    let settings = try await store.alertSettings(forServer: id, topic: "alerts")
    #expect(settings.muted == true)
    #expect(settings.minAlertPriority == 4)
}

/// A message for a topic with no subscription row must not be silently
/// suppressed — defaulting to muted would hide messages the user can see in
/// the archive but was never told about.
@Test func alertSettingsForAnUnknownTopicDefaultToAlerting() async throws {
    let container = try StoreFixtures.inMemoryContainer()
    let id = UUID()
    let context = ModelContext(container)
    context.insert(Server(id: id, name: "Alpha", baseURLString: "https://a.example.com"))
    try context.save()

    let settings = try await MessageStore(modelContainer: container)
        .alertSettings(forServer: id, topic: "nope")
    #expect(settings.muted == false)
    #expect(settings.minAlertPriority == 1)
}

// MARK: - search

/// Inserts a `Message` directly, bypassing `NtfyEvent`, so a test can set
/// `priority`, `tags`, `title`, and `isRead` independently of one another.
@discardableResult
private func insertMessage(_ context: ModelContext, serverID: UUID, topic: String = "alerts",
                           id: String, time: Int, title: String? = nil, body: String,
                           priority: Int = 3, tags: [String] = [], isRead: Bool = false) -> Message {
    let message = Message(serverID: serverID, topic: topic, messageID: id,
                          time: Date(timeIntervalSince1970: TimeInterval(time)),
                          title: title, body: body, priority: priority, tags: tags,
                          isRead: isRead)
    context.insert(message)
    return message
}

private func makeSearchStore() throws -> (MessageStore, ModelContext, UUID) {
    let container = try StoreFixtures.inMemoryContainer()
    let serverID = UUID()
    let context = ModelContext(container)
    let server = Server(id: serverID, name: "Example", baseURLString: "https://ntfy.example.com")
    context.insert(server)
    context.insert(Subscription(topic: "alerts", server: server))
    context.insert(Subscription(topic: "deploys", server: server))
    try context.save()
    return (MessageStore(modelContainer: container), context, serverID)
}

@Test func searchFiltersByTopic() async throws {
    let (store, context, serverID) = try makeSearchStore()
    insertMessage(context, serverID: serverID, topic: "alerts", id: "a", time: 100, body: "a")
    insertMessage(context, serverID: serverID, topic: "deploys", id: "d", time: 200, body: "d")
    try context.save()

    let results = try await store.search(MessageQuery(topic: "alerts"))
    #expect(results.map(\.id).count == 1)
    #expect(results.first?.topic == "alerts")
}

@Test func searchMatchesTitleOrBodyCaseInsensitively() async throws {
    let (store, context, serverID) = try makeSearchStore()
    insertMessage(context, serverID: serverID, id: "a", time: 100,
                  title: "Deploy Finished", body: "all good")
    insertMessage(context, serverID: serverID, id: "b", time: 200,
                  title: nil, body: "server is DOWN")
    insertMessage(context, serverID: serverID, id: "c", time: 300,
                  title: nil, body: "unrelated")
    try context.save()

    let byTitle = try await store.search(MessageQuery(searchText: "deploy"))
    #expect(byTitle.map(\.id) == [Message.uniqueKey(serverID: serverID, topic: "alerts", messageID: "a")])

    let byBody = try await store.search(MessageQuery(searchText: "down"))
    #expect(byBody.map(\.id) == [Message.uniqueKey(serverID: serverID, topic: "alerts", messageID: "b")])
}

@Test func searchAppliesMinPriority() async throws {
    let (store, context, serverID) = try makeSearchStore()
    insertMessage(context, serverID: serverID, id: "low", time: 100, body: "low", priority: 2)
    insertMessage(context, serverID: serverID, id: "high", time: 200, body: "high", priority: 5)
    try context.save()

    let results = try await store.search(MessageQuery(minPriority: 4))
    #expect(results.map(\.id) == [Message.uniqueKey(serverID: serverID, topic: "alerts", messageID: "high")])
}

@Test func searchAppliesTagFilter() async throws {
    let (store, context, serverID) = try makeSearchStore()
    insertMessage(context, serverID: serverID, id: "tagged", time: 100, body: "a", tags: ["urgent"])
    insertMessage(context, serverID: serverID, id: "untagged", time: 200, body: "b")
    try context.save()

    let results = try await store.search(MessageQuery(tag: "urgent"))
    #expect(results.map(\.id) == [Message.uniqueKey(serverID: serverID, topic: "alerts", messageID: "tagged")])
}

/// A tag containing `"|"` would break the delimiter scheme, so `joinTags`
/// drops it from the joined form rather than escaping it — see its doc
/// comment for why. This does not touch `tags` itself or the rest of the
/// row; the message is simply not findable by *that* tag via `search`.
@Test func joinTagsDropsATagContainingThePipeDelimiter() {
    #expect(Message.joinTags(["safe", "bad|tag", "also-safe"]) == "|safe|also-safe|")
    #expect(Message.joinTags(["bad|tag"]) == "")
    #expect(Message.joinTags([]) == "")
}

/// `Message.joinTags` delimits with a leading AND trailing `"|"` precisely
/// so a search for `"alert"` cannot match a message tagged only `"alerts"`
/// — pins the reason those delimiters exist, not just that tag filtering
/// works at all.
@Test func searchTagFilterDoesNotMatchATagThatMerelyStartsWithTheQuery() async throws {
    let (store, context, serverID) = try makeSearchStore()
    insertMessage(context, serverID: serverID, id: "longer", time: 100, body: "a", tags: ["alerts"])
    insertMessage(context, serverID: serverID, id: "exact", time: 200, body: "b", tags: ["alert"])
    try context.save()

    let results = try await store.search(MessageQuery(tag: "alert"))
    #expect(results.map(\.id) == [Message.uniqueKey(serverID: serverID, topic: "alerts", messageID: "exact")])
}

/// Mutation-verified (see the tag-denormalization report): `tag` is now
/// folded into the same SQL predicate as every other filter, so it must
/// page exactly like they do — the same shape `aTopicFilteredPageIsFiltered
/// BeforeTheLimit`/`searchLimitIsAppliedAfterFilteringNotBefore` pin for
/// `topic`, exercised here for `tag` since it used to be the one field that
/// could not join that predicate at all.
@Test func searchTagFilterRespectsLimitAndOffset() async throws {
    let (store, context, serverID) = try makeSearchStore()
    insertMessage(context, serverID: serverID, id: "u1", time: 100, body: "urgent-oldest", tags: ["urgent"])
    insertMessage(context, serverID: serverID, id: "d1", time: 200, body: "deploys-old", tags: ["deploy"])
    insertMessage(context, serverID: serverID, id: "u2", time: 300, body: "urgent-middle", tags: ["urgent"])
    insertMessage(context, serverID: serverID, id: "d2", time: 400, body: "deploys-mid", tags: ["deploy"])
    insertMessage(context, serverID: serverID, id: "u3", time: 500, body: "urgent-newest", tags: ["urgent"])
    try context.save()

    let page = try await store.search(MessageQuery(tag: "urgent", limit: 2))
    #expect(page.map(\.body) == ["urgent-newest", "urgent-middle"])

    let secondPage = try await store.search(MessageQuery(tag: "urgent", limit: 2, offset: 2))
    #expect(secondPage.map(\.body) == ["urgent-oldest"])
}

@Test func searchAppliesUnreadOnly() async throws {
    let (store, context, serverID) = try makeSearchStore()
    insertMessage(context, serverID: serverID, id: "read", time: 100, body: "a", isRead: true)
    insertMessage(context, serverID: serverID, id: "unread", time: 200, body: "b", isRead: false)
    try context.save()

    let results = try await store.search(MessageQuery(unreadOnly: true))
    #expect(results.map(\.id) == [Message.uniqueKey(serverID: serverID, topic: "alerts", messageID: "unread")])
}

@Test func searchAppliesSinceAndUntil() async throws {
    let (store, context, serverID) = try makeSearchStore()
    insertMessage(context, serverID: serverID, id: "early", time: 100, body: "a")
    insertMessage(context, serverID: serverID, id: "mid", time: 200, body: "b")
    insertMessage(context, serverID: serverID, id: "late", time: 300, body: "c")
    try context.save()

    let results = try await store.search(MessageQuery(
        since: Date(timeIntervalSince1970: 150), until: Date(timeIntervalSince1970: 250)))
    #expect(results.map(\.id) == [Message.uniqueKey(serverID: serverID, topic: "alerts", messageID: "mid")])
}

/// Mutation-verified: the topic/server filter must live IN the predicate,
/// not be applied to rows a `fetchLimit` already truncated — the same bug
/// class `aTopicFilteredPageIsFilteredBeforeTheLimit` covers for
/// `messages(forServer:topic:limit:)`, exercised here for `search`. Run
/// once against a deliberately broken build (limit applied before the
/// topic filter): FAILS as expected — the broken build returns
/// `["alerts-newest"]` because it takes the two newest rows overall (one a
/// `deploys` row) before filtering, instead of the two newest `alerts`
/// rows.
@Test func searchLimitIsAppliedAfterFilteringNotBefore() async throws {
    let (store, context, serverID) = try makeSearchStore()
    insertMessage(context, serverID: serverID, topic: "alerts", id: "a1", time: 100, body: "alerts-oldest")
    insertMessage(context, serverID: serverID, topic: "deploys", id: "d1", time: 200, body: "deploys-old")
    insertMessage(context, serverID: serverID, topic: "alerts", id: "a2", time: 300, body: "alerts-middle")
    insertMessage(context, serverID: serverID, topic: "deploys", id: "d2", time: 400, body: "deploys-mid")
    insertMessage(context, serverID: serverID, topic: "alerts", id: "a3", time: 500, body: "alerts-newest")
    insertMessage(context, serverID: serverID, topic: "deploys", id: "d3", time: 600, body: "deploys-newest")
    try context.save()

    let page = try await store.search(MessageQuery(topic: "alerts", limit: 2))
    #expect(page.map(\.body) == ["alerts-newest", "alerts-middle"])
}

@Test func searchOffsetPagesPastEarlierRows() async throws {
    let (store, context, serverID) = try makeSearchStore()
    insertMessage(context, serverID: serverID, id: "a", time: 100, body: "one")
    insertMessage(context, serverID: serverID, id: "b", time: 200, body: "two")
    insertMessage(context, serverID: serverID, id: "c", time: 300, body: "three")
    try context.save()

    let page = try await store.search(MessageQuery(limit: 2, offset: 1))
    #expect(page.map(\.body) == ["two", "one"])
}

/// `search`'s tag filter matches `tagsJoined`, not `tags`, and there is no
/// query that can find "rows whose `tagsJoined` needs recomputing" using
/// `tagsJoined` itself — `prune`'s already-scheduled full-table scan is
/// what repairs a row written (or, here, corrupted) before `tagsJoined` was
/// kept in sync. This is the actual transition the migration exists for:
/// unfindable by tag before `prune` runs, findable after, with no other
/// change to the row.
@Test func pruneBackfillsAStaleTagsJoinedSoTheRowBecomesTagSearchable() async throws {
    let (store, context, serverID) = try makeSearchStore()
    let message = insertMessage(context, serverID: serverID, id: "a", time: 100,
                                body: "x", tags: ["urgent"])
    // Simulate a row written before `tagsJoined` existed (or one that
    // otherwise fell out of sync with `tags`).
    message.tagsJoined = ""
    try context.save()

    let before = try await store.search(MessageQuery(tag: "urgent"))
    #expect(before.isEmpty)

    _ = try await store.prune(policy: RetentionPolicy(maxAge: 999_999, maxMessagesPerTopic: 999),
                              now: Date(timeIntervalSince1970: 100), attachmentsDirectory: nil)

    let after = try await store.search(MessageQuery(tag: "urgent"))
    #expect(after.map(\.id) == [Message.uniqueKey(serverID: serverID, topic: "alerts", messageID: "a")])
}

// MARK: - topicSummaries / unreadCount

@Test func topicSummariesReportUnreadAndTotalCounts() async throws {
    let (store, context, serverID) = try makeSearchStore()
    insertMessage(context, serverID: serverID, topic: "alerts", id: "a1", time: 100, body: "a", isRead: true)
    insertMessage(context, serverID: serverID, topic: "alerts", id: "a2", time: 200, body: "b", isRead: false)
    insertMessage(context, serverID: serverID, topic: "deploys", id: "d1", time: 300, body: "c", isRead: false)
    try context.save()

    // No `.sorted` here: `topicSummaries()` orders by topic name itself
    // (subscriptions have no natural relationship order), so asserting on
    // its raw result actually verifies that ordering rather than re-imposing
    // one over it.
    let summaries = try await store.topicSummaries()
    #expect(summaries.count == 2)
    #expect(summaries[0].topic == "alerts")
    #expect(summaries[0].totalCount == 2)
    #expect(summaries[0].unreadCount == 1)
    #expect(summaries[1].topic == "deploys")
    #expect(summaries[1].totalCount == 1)
    #expect(summaries[1].unreadCount == 1)
}

@Test func unreadCountScopesToServerAndTopic() async throws {
    let (store, context, serverID) = try makeSearchStore()
    insertMessage(context, serverID: serverID, topic: "alerts", id: "a1", time: 100, body: "a", isRead: false)
    insertMessage(context, serverID: serverID, topic: "alerts", id: "a2", time: 200, body: "b", isRead: true)
    insertMessage(context, serverID: serverID, topic: "deploys", id: "d1", time: 300, body: "c", isRead: false)
    try context.save()

    #expect(try await store.unreadCount(serverID: serverID, topic: "alerts") == 1)
    #expect(try await store.unreadCount(serverID: serverID, topic: nil) == 2)
}

// MARK: - markRead / markAllRead / deleteMessages

@Test func markReadTogglesIsReadOnNamedRowsOnly() async throws {
    let (store, context, serverID) = try makeSearchStore()
    insertMessage(context, serverID: serverID, id: "a", time: 100, body: "a")
    insertMessage(context, serverID: serverID, id: "b", time: 200, body: "b")
    try context.save()
    let keyA = Message.uniqueKey(serverID: serverID, topic: "alerts", messageID: "a")
    let keyB = Message.uniqueKey(serverID: serverID, topic: "alerts", messageID: "b")

    try await store.markRead([keyA], read: true)
    let page = try await store.messages(forServer: serverID, topic: nil, limit: 10)
    #expect(page.first(where: { $0.id == keyA })?.isRead == true)
    #expect(page.first(where: { $0.id == keyB })?.isRead == false)

    try await store.markRead([keyA], read: false)
    let after = try await store.messages(forServer: serverID, topic: nil, limit: 10)
    #expect(after.first(where: { $0.id == keyA })?.isRead == false)
}

@Test func markAllReadOnlyTouchesScopedUnreadRows() async throws {
    let (store, context, serverID) = try makeSearchStore()
    insertMessage(context, serverID: serverID, topic: "alerts", id: "a", time: 100, body: "a")
    insertMessage(context, serverID: serverID, topic: "deploys", id: "d", time: 200, body: "d")
    try context.save()

    try await store.markAllRead(serverID: serverID, topic: "alerts")
    #expect(try await store.unreadCount(serverID: serverID, topic: "alerts") == 0)
    #expect(try await store.unreadCount(serverID: serverID, topic: "deploys") == 1)
}

@Test func deleteMessagesRemovesOnlyTheNamedRows() async throws {
    let (store, context, serverID) = try makeSearchStore()
    insertMessage(context, serverID: serverID, id: "a", time: 100, body: "a")
    insertMessage(context, serverID: serverID, id: "b", time: 200, body: "b")
    try context.save()
    let keyA = Message.uniqueKey(serverID: serverID, topic: "alerts", messageID: "a")

    try await store.deleteMessages([keyA])
    #expect(try await store.messageCount() == 1)
    let remaining = try await store.messages(forServer: serverID, topic: nil, limit: 10)
    #expect(remaining.map(\.body) == ["b"])
}

/// `deleteMessages` reuses `prune`'s guarded attachment-file deletion
/// rather than a second copy of it — this pins that the file is actually
/// removed, not just that the call compiles.
@Test func deleteMessagesRemovesTheAttachmentFileOnDisk() async throws {
    let (store, context, serverID) = try makeSearchStore()
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("deleteMessages-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let file = directory.appendingPathComponent("graph.png")
    try Data("png".utf8).write(to: file)

    let message = Message(serverID: serverID, topic: "alerts", messageID: "a",
                          time: Date(timeIntervalSince1970: 1), body: "m",
                          attachment: Attachment(name: "graph.png",
                                                 urlString: "https://example.com/graph.png",
                                                 localFilename: "graph.png"))
    context.insert(message)
    try context.save()
    let key = Message.uniqueKey(serverID: serverID, topic: "alerts", messageID: "a")

    try await store.deleteMessages([key], attachmentsDirectory: directory)
    #expect(try await store.messageCount() == 0)
    #expect(FileManager.default.fileExists(atPath: file.path) == false)
}

/// The `attachmentsDirectory` parameter defaults to `nil`, so a caller that
/// omits it (tests, or a build with no downloader) deletes the row without
/// attempting any file operation — this is the contrast that proves the
/// test above is actually exercising the file-deletion path, not something
/// that always happens regardless.
@Test func deleteMessagesLeavesTheFileAloneWhenNoDirectoryIsGiven() async throws {
    let (store, context, serverID) = try makeSearchStore()
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("deleteMessages-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let file = directory.appendingPathComponent("graph.png")
    try Data("png".utf8).write(to: file)

    let message = Message(serverID: serverID, topic: "alerts", messageID: "a",
                          time: Date(timeIntervalSince1970: 1), body: "m",
                          attachment: Attachment(name: "graph.png",
                                                 urlString: "https://example.com/graph.png",
                                                 localFilename: "graph.png"))
    context.insert(message)
    try context.save()
    let key = Message.uniqueKey(serverID: serverID, topic: "alerts", messageID: "a")

    try await store.deleteMessages([key])
    #expect(try await store.messageCount() == 0)
    #expect(FileManager.default.fileExists(atPath: file.path) == true)
}

// MARK: - addServer / removeServer

@Test func addServerPersistsAndIsReturnedByServers() async throws {
    let container = try StoreFixtures.inMemoryContainer()
    let store = MessageStore(modelContainer: container)

    let id = try await store.addServer(name: "New", baseURL: URL(string: "https://new.example.com")!,
                                       authKindRaw: "unauthenticated")
    let servers = try await store.servers()
    #expect(servers.count == 1)
    #expect(servers.first?.id == id)
    #expect(servers.first?.name == "New")
}

/// Mutation-verified: `Message.serverID` is a plain value, not a
/// relationship, so `Server`'s cascade delete rule does not reach it —
/// removing that explicit deletion (leaving only `modelContext.delete(server)`)
/// FAILS this test as expected: `messageCount()` comes back `1`, the
/// orphaned row, instead of `0`.
@Test func removeServerDeletesItsMessages() async throws {
    let (store, context, serverID) = try makeSearchStore()
    insertMessage(context, serverID: serverID, id: "a", time: 100, body: "a")
    try context.save()
    #expect(try await store.messageCount() == 1)

    try await store.removeServer(serverID)
    #expect(try await store.messageCount() == 0)
}

/// Companion to the mutation-verified test above: proves the deletion is
/// scoped to the removed server, not a global wipe — a broken
/// implementation that deleted every `Message` row regardless of
/// `serverID` would also pass a test that only checked the removed
/// server's count went to zero.
@Test func removeServerLeavesOtherServersMessagesIntact() async throws {
    let container = try StoreFixtures.inMemoryContainer()
    let context = ModelContext(container)
    let removedID = UUID()
    let keptID = UUID()
    let removedServer = Server(id: removedID, name: "Removed", baseURLString: "https://a.example.com")
    let keptServer = Server(id: keptID, name: "Kept", baseURLString: "https://b.example.com")
    context.insert(removedServer)
    context.insert(keptServer)
    context.insert(Subscription(topic: "alerts", server: removedServer))
    context.insert(Subscription(topic: "alerts", server: keptServer))
    try context.save()
    insertMessage(context, serverID: removedID, id: "a", time: 100, body: "a")
    insertMessage(context, serverID: keptID, id: "b", time: 200, body: "b")
    try context.save()

    let store = MessageStore(modelContainer: container)
    try await store.removeServer(removedID)

    #expect(try await store.messageCount() == 1)
    let remaining = try await store.messages(forServer: keptID, topic: nil, limit: 10)
    #expect(remaining.map(\.body) == ["b"])
}

@Test func removeServerAlsoRemovesItsSubscriptions() async throws {
    let (store, _, serverID) = try makeSearchStore()
    try await store.removeServer(serverID)
    let servers = try await store.servers()
    #expect(servers.isEmpty)
}

// MARK: - addTopic / removeTopic

/// Mutation-verified: dropping the `server.caughtUpTo = nil` line makes
/// this FAIL as expected — `caughtUpTo` comes back still set to `t`
/// instead of `nil`.
@Test func addTopicResetsCaughtUpTo() async throws {
    let (store, serverID) = try makeStore()
    let t = Date(timeIntervalSince1970: 1_788_353_322)
    try await store.setCaughtUpTo(t, forServer: serverID)
    #expect(try await store.caughtUpTo(forServer: serverID) == t)

    try await store.addTopic("deploys", toServer: serverID)
    #expect(try await store.caughtUpTo(forServer: serverID) == nil)
}

@Test func addTopicCreatesASubscriptionRow() async throws {
    let (store, serverID) = try makeStore()
    try await store.addTopic("deploys", toServer: serverID)
    let marks = try await store.watermarks(forServer: serverID)
    #expect(marks.map(\.topic).sorted() == ["alerts", "deploys"])
}

/// Adding a topic the server is already subscribed to must not create a
/// second `Subscription` row, or every `first(where:)` lookup in the store
/// (alert settings, watermark advance) would nondeterministically pick
/// either one.
@Test func addTopicIsIdempotentForAnAlreadySubscribedTopic() async throws {
    let (store, serverID) = try makeStore()
    try await store.addTopic("alerts", toServer: serverID)
    let marks = try await store.watermarks(forServer: serverID)
    #expect(marks.count == 1)
}

@Test func removeTopicDeletesTheSubscriptionButKeepsMessages() async throws {
    let (store, context, serverID) = try makeSearchStore()
    insertMessage(context, serverID: serverID, topic: "alerts", id: "a", time: 100, body: "a")
    try context.save()

    try await store.removeTopic("alerts", fromServer: serverID)
    let marks = try await store.watermarks(forServer: serverID)
    #expect(marks.map(\.topic) == ["deploys"])
    #expect(try await store.messageCount() == 1)
}

// MARK: - setAlertSettings

@Test func setAlertSettingsWritesToTheSubscriptionRow() async throws {
    let (store, serverID) = try makeStore()
    try await store.setAlertSettings(TopicAlertSettings(muted: true, minAlertPriority: 5),
                                     forServer: serverID, topic: "alerts")
    let settings = try await store.alertSettings(forServer: serverID, topic: "alerts")
    #expect(settings.muted == true)
    #expect(settings.minAlertPriority == 5)
}
