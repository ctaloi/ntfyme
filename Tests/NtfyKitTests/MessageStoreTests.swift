import Foundation
import SwiftData
import Testing
@testable import NtfyKit

private func event(_ id: String, topic: String = "alerts", time: Int, body: String) -> NtfyEvent {
    let json = """
    {"id":"\(id)","time":\(time),"event":"message","topic":"\(topic)","message":"\(body)"}
    """
    return try! JSONDecoder().decode(NtfyEvent.self, from: Data(json.utf8))
}

private func eventWithAttachment(_ id: String, topic: String = "alerts", time: Int, body: String,
                                 name: String = "graph.png", url: String = "https://example.com/graph.png",
                                 type: String? = "image/png", size: Int? = 1024) -> NtfyEvent {
    let typeJSON = type.map { "\"\($0)\"" } ?? "null"
    let sizeJSON = size.map(String.init) ?? "null"
    let json = """
    {"id":"\(id)","time":\(time),"event":"message","topic":"\(topic)","message":"\(body)",
     "attachment":{"name":"\(name)","url":"\(url)","type":\(typeJSON),"size":\(sizeJSON)}}
    """
    return try! JSONDecoder().decode(NtfyEvent.self, from: Data(json.utf8))
}

private struct CommandFailed: Error, CustomStringConvertible {
    let executable: String
    let arguments: [String]
    let output: String
    var description: String {
        "\(executable) \(arguments.joined(separator: " ")) failed: \(output)"
    }
}

/// Runs `executable` and returns its combined stdout/stderr, throwing if it
/// exits non-zero or cannot be launched at all (e.g. the path does not
/// exist). Used by `aFailedSaveRollsBackSoARetriedBatchIsNotMistakenForA
/// Duplicate` to drive `hdiutil` — a test that silently skipped when the
/// tool it depends on is missing would report green while pinning nothing,
/// so this throws instead.
private func run(_ executable: String, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
        throw CommandFailed(executable: executable, arguments: arguments, output: output)
    }
    return output
}

/// Opens a `MessageStore`-ready container on a tiny scratch HFS+ disk
/// image, seeded with a `Server`/`Subscription("alerts")` for `serverID`,
/// and returns it alongside `fillerURL` — pass it to `fillVolume(at:)` to
/// force a real `ENOSPC` on demand — and a `cleanup` closure the caller
/// MUST invoke (typically via `defer`) to unmount the image and remove its
/// scratch directory.
///
/// Shared by every test that needs a genuine, connection-scoped `save()`
/// failure. See `aFailedSaveRollsBackSoARetriedBatchIsNotMistakenForA
/// Duplicate`'s doc comment for why a disk image, not `RLIMIT_FSIZE` or a
/// permission-revoked connection.
private func makeFullDiskFixture(serverID: UUID) throws
    -> (container: ModelContainer, fillerURL: URL, cleanup: () -> Void) {
    let workDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MessageStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)

    let imagePath = workDirectory.appendingPathComponent("tiny.dmg").path
    let mountPoint = workDirectory.appendingPathComponent("mnt")
    try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)

    // 8 MiB comfortably fits this schema's catalog plus a handful of rows
    // (asserted below by `try`, not caught) while still filling in well
    // under a second.
    _ = try run("/usr/bin/hdiutil", ["create", "-size", "8m", "-fs", "HFS+",
                                     "-volname", "NtfyTinyTestVolume", "-quiet", imagePath])
    _ = try run("/usr/bin/hdiutil", ["attach", imagePath, "-nobrowse", "-quiet",
                                     "-mountpoint", mountPoint.path])
    let cleanup = {
        // Always detach, even if an assertion later throws — an undetached
        // scratch volume leaks for the rest of the test run, and possibly
        // beyond it.
        _ = try? run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet"])
        try? FileManager.default.removeItem(at: workDirectory)
    }

    let storeURL = mountPoint.appendingPathComponent("store.sqlite")
    let container = try ModelContainer(
        for: Message.self, Subscription.self, Server.self, Attachment.self,
        configurations: ModelConfiguration(url: storeURL))
    let setupContext = ModelContext(container)
    let server = Server(id: serverID, name: "Example", baseURLString: "https://ntfy.example.com")
    setupContext.insert(server)
    setupContext.insert(Subscription(topic: "alerts", server: server))
    try setupContext.save()

    return (container, mountPoint.appendingPathComponent("filler"), cleanup)
}

/// Writes to `fillerURL` until the volume backing it is exhausted. Shrinking
/// chunk sizes, each looped to exhaustion, rather than one fixed size: a
/// single 64 KiB loop leaves however much slack is smaller than 64 KiB
/// unclaimed, and that slack was enough room for SQLite to grow its WAL by
/// one small page — confirmed empirically against the first version of this
/// fill, which left enough room that a write meant to fail succeeded
/// outright. Working down to a 1-byte chunk squeezes out whatever is left,
/// well under SQLite's default page size.
private func fillVolume(at fillerURL: URL) throws {
    FileManager.default.createFile(atPath: fillerURL.path, contents: nil)
    let fillerHandle = try FileHandle(forWritingTo: fillerURL)
    for chunkSize in [1_048_576, 65_536, 4_096, 512, 64, 8, 1] {
        let chunk = Data(repeating: 0, count: chunkSize)
        while (try? fillerHandle.write(contentsOf: chunk)) != nil {}
    }
    try? fillerHandle.close()
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

/// `event.attachment` was previously dropped at the door — nothing
/// downstream (`AttachmentDownloader`, Quick Look, `prune`'s file cleanup)
/// could ever run because nothing was ever persisted. This pins that the
/// metadata now survives the round trip, with `localFilename` starting
/// `nil` — nothing has downloaded anything yet at insert time.
@Test func insertingPersistsAttachmentMetadata() async throws {
    let (store, serverID) = try makeStore()
    _ = try await store.insert(
        [eventWithAttachment("a", time: 100, body: "one", name: "graph.png",
                             url: "https://example.com/graph.png", type: "image/png", size: 2048)],
        serverID: serverID)

    let messages = try await store.messages(forServer: serverID, topic: nil, limit: 10)
    let attachment = messages.first?.attachment
    #expect(attachment?.name == "graph.png")
    #expect(attachment?.type == "image/png")
    #expect(attachment?.size == 2048)
    #expect(attachment?.localFilename == nil)
}

/// The contrast case: an event with no `attachment` field must not somehow
/// acquire one — proves the test above is pinning something that varies,
/// not something that is always present regardless.
@Test func insertingWithoutAttachmentLeavesAttachmentNil() async throws {
    let (store, serverID) = try makeStore()
    _ = try await store.insert([event("a", time: 100, body: "one")], serverID: serverID)
    let messages = try await store.messages(forServer: serverID, topic: nil, limit: 10)
    #expect(messages.first?.attachment == nil)
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
/// injection, so there is no protocol to substitute here. Three techniques
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
/// - `RLIMIT_FSIZE` + ignoring `SIGXFSZ`: this genuinely produced a clean,
///   fast, connection-local `EFBIG` failure — but `setrlimit` is
///   PROCESS-wide, and Swift Testing runs the whole suite in one process
///   with tests in parallel. For as long as the limit was lowered, any
///   concurrently running test that wrote a file anywhere failed alongside
///   this one with an unrelated-looking `EFBIG` — confirmed: the suite was
///   green with this test skipped, and red on every full run with a
///   *different* random victim each time (whichever test happened to be
///   mid-write). A process-global mutation — `setrlimit`, `signal`,
///   `chdir`, `umask` — is not safe in a parallel test process however
///   tightly its window is scoped; the window is not the problem,
///   concurrency during the window is.
///
/// A small HFS+ disk image, mounted for this test alone, scopes the
/// induced failure (genuine `ENOSPC`, not `EFBIG`) to one filesystem that
/// nothing else touches — no process-wide state, so no blast radius on a
/// concurrently running test. `hdiutil` is a system tool; if it is ever
/// unavailable, `run(_:_:)` throws rather than this test silently skipping.
@Test func aFailedSaveRollsBackSoARetriedBatchIsNotMistakenForADuplicate() async throws {
    let serverID = UUID()
    let fixture = try makeFullDiskFixture(serverID: serverID)
    defer { fixture.cleanup() }

    let store = MessageStore(modelContainer: fixture.container)
    let batch = [event("a", time: 100, body: "one")]

    // The volume is full, not the store misconfigured or unopenable — this
    // is the `save()` failure the test is actually about.
    try fillVolume(at: fixture.fillerURL)
    await #expect(throws: (any Error).self) {
        try await store.insert(batch, serverID: serverID)
    }

    // Free the room back up — mirroring however a real transient
    // disk-full condition would clear — and retry the SAME batch,
    // unchanged, on the SAME store (same actor, same `modelContext`),
    // exactly as `Ingest.Buffer` does after a failed flush.
    try FileManager.default.removeItem(at: fixture.fillerURL)

    let retry = try await store.insert(batch, serverID: serverID)
    #expect(retry.stored.map(\.id) == ["a"])
    #expect(retry.duplicatesSkipped == 0)
    #expect(try await store.messageCount() == 1)
}

/// `deleteMessages` must not delete the attachment file before `save()`
/// commits the row deletion — the sharpest case among the mutator-rollback
/// fixes, because the file, unlike a database row, has no `rollback()`. If
/// the file were removed first, a failed save would leave it gone, the row
/// still present, and the caller told the delete failed: data loss with no
/// way for the caller to detect it. This proves the file survives a failed
/// save.
///
/// Deliberately retries on a FRESH `MessageStore`, not the one that
/// experienced the failure. A genuine finding surfaced while writing this
/// test: after a `save()` fails, that SAME actor's `modelContext` can
/// report an already-rolled-back-but-still-persisted row as absent from a
/// plain `fetch`/`fetchCount` — verified against a second, independent
/// context on the same container, which sees it correctly; unaffected by
/// `includePendingChanges`, since `rollback()` already empties the
/// pending-changes set this flag controls. One arbitrary fetch on the
/// affected context clears the condition. `deleteMessages` has no
/// production retry path — deletion is user-initiated, unlike `insert`,
/// which `Ingest.Buffer` retries automatically — so pinning a same-context
/// retry here would assert a contract this store does not claim to
/// support. A fresh store instead proves what this fix actually
/// guarantees: the underlying row and file are intact and deletable.
///
/// Mutation-verified: moving the file-deletion loop back to before
/// `modelContext.save()` (the ordering this replaced) makes the first
/// assertion FAIL as expected — the file is gone even though `save()`
/// threw.
@Test func deleteMessagesLeavesTheFileInPlaceWhenSaveFails() async throws {
    let serverID = UUID()
    let fixture = try makeFullDiskFixture(serverID: serverID)
    defer { fixture.cleanup() }

    let attachmentsDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("deleteMessages-fail-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: attachmentsDirectory) }
    let file = attachmentsDirectory.appendingPathComponent("graph.png")
    try Data("png".utf8).write(to: file)

    // Written on the not-yet-full volume, via a second context, exactly as
    // `aFailedSaveRollsBackSoARetriedBatchIsNotMistakenForADuplicate` seeds
    // its `Server`/`Subscription` row.
    let setupContext = ModelContext(fixture.container)
    let message = Message(serverID: serverID, topic: "alerts", messageID: "a",
                          time: Date(timeIntervalSince1970: 1), body: "m",
                          attachment: Attachment(name: "graph.png",
                                                 urlString: "https://example.com/graph.png",
                                                 localFilename: "graph.png"))
    setupContext.insert(message)
    try setupContext.save()

    let store = MessageStore(modelContainer: fixture.container)
    let key = Message.uniqueKey(serverID: serverID, topic: "alerts", messageID: "a")

    try fillVolume(at: fixture.fillerURL)
    await #expect(throws: (any Error).self) {
        try await store.deleteMessages([key], attachmentsDirectory: attachmentsDirectory)
    }
    #expect(FileManager.default.fileExists(atPath: file.path) == true)

    try FileManager.default.removeItem(at: fixture.fillerURL)
    let retryStore = MessageStore(modelContainer: fixture.container)
    try await retryStore.deleteMessages([key], attachmentsDirectory: attachmentsDirectory)
    #expect(FileManager.default.fileExists(atPath: file.path) == false)
    #expect(try await retryStore.messageCount() == 0)
}

/// The `addTopic` counterpart: proves `server.caughtUpTo = nil` does not
/// survive a failed save to leak into an unrelated LATER successful one.
/// Asserting `caughtUpTo == t` immediately after the failed call would only
/// prove `rollback()` cleaned the object graph for THIS context; it would
/// not prove the actual leak the team flagged — an unrelated `insert()`
/// later committing `caughtUpTo = nil` behind the caller's back, silently
/// forcing a full-cache replay for a topic the caller was told was never
/// added. The independent `insert()` after the failure is what makes this
/// a leak test rather than a same-call rollback test.
///
/// Mutation-verified: removing the `catch { rollback() }` around
/// `addTopic`'s `save()` makes the final assertion FAIL as expected —
/// `caughtUpTo` comes back `nil` after the unrelated `insert()`, even
/// though `addTopic` itself threw.
@Test func addTopicDoesNotLeakCaughtUpToResetWhenSaveFails() async throws {
    let serverID = UUID()
    let fixture = try makeFullDiskFixture(serverID: serverID)
    defer { fixture.cleanup() }

    let store = MessageStore(modelContainer: fixture.container)
    let t = Date(timeIntervalSince1970: 1_788_353_322)
    try await store.setCaughtUpTo(t, forServer: serverID)
    #expect(try await store.caughtUpTo(forServer: serverID) == t)

    try fillVolume(at: fixture.fillerURL)
    await #expect(throws: (any Error).self) {
        try await store.addTopic("deploys", toServer: serverID)
    }

    try FileManager.default.removeItem(at: fixture.fillerURL)

    // An unrelated, independently-successful save — exactly the kind that
    // would otherwise commit the leaked `caughtUpTo = nil` mutation.
    _ = try await store.insert([event("a", time: 100, body: "one")], serverID: serverID)

    #expect(try await store.caughtUpTo(forServer: serverID) == t)
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

    try await store.deleteMessages([keyA], attachmentsDirectory: nil)
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

/// `attachmentsDirectory` has no default — a caller must pass `nil`
/// explicitly (tests, or a build with no downloader) to delete the row
/// without attempting any file operation — this is the contrast that
/// proves the test above is actually exercising the file-deletion path,
/// not something that always happens regardless.
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

    try await store.deleteMessages([key], attachmentsDirectory: nil)
    #expect(try await store.messageCount() == 0)
    #expect(FileManager.default.fileExists(atPath: file.path) == true)
}

// MARK: - setAttachmentLocalFilename

@Test func setAttachmentLocalFilenameRecordsTheDownloadedFile() async throws {
    let (store, context, serverID) = try makeSearchStore()
    let message = Message(serverID: serverID, topic: "alerts", messageID: "a",
                          time: Date(timeIntervalSince1970: 1), body: "m",
                          attachment: Attachment(name: "graph.png",
                                                 urlString: "https://example.com/graph.png"))
    context.insert(message)
    try context.save()
    let key = Message.uniqueKey(serverID: serverID, topic: "alerts", messageID: "a")

    let before = try await store.messages(forServer: serverID, topic: nil, limit: 10)
    #expect(before.first?.attachment?.localFilename == nil)

    try await store.setAttachmentLocalFilename("a1b2c3.png", forMessage: key)
    let after = try await store.messages(forServer: serverID, topic: nil, limit: 10)
    #expect(after.first?.attachment?.localFilename == "a1b2c3.png")
}

/// A download can race a concurrent deletion or a message that never had
/// an attachment to begin with — neither is a caller bug, and both must be
/// a silent no-op rather than throwing for a result nobody can act on
/// anymore.
///
/// Not mutation-verified: the only way to break this specific guard is a
/// force-unwrap, which would crash the whole test PROCESS rather than fail
/// this one test — the same process-wide-blast-radius problem that ruled
/// out `RLIMIT_FSIZE` elsewhere in this file, but worse, since a crash
/// (unlike a failing assertion) would also take down any other test
/// running concurrently in this same parallel test process. Reasoned
/// instead: `try modelContext.fetch(descriptor).first` on a key naming no
/// row is `nil`, `nil?.attachment` is `nil`, and the `guard let ... else`
/// returns before anything is mutated or saved — there is no `save()` at
/// all in that path for a crash-free mutation to corrupt.
@Test func setAttachmentLocalFilenameIsANoOpWhenTheMessageDoesNotExist() async throws {
    let (store, serverID) = try makeStore()
    let key = Message.uniqueKey(serverID: serverID, topic: "alerts", messageID: "nope")
    try await store.setAttachmentLocalFilename("a1b2c3.png", forMessage: key)
    // No throw is the assertion; nothing else to check against an empty store.
}

/// Mutation-verified: replacing the guard's `?? nil` effect with a
/// fallback that creates and inserts a placeholder `Attachment` when the
/// message has none (`?? Attachment(name: "x", urlString: "y")`, saved
/// unconditionally) makes the final assertion FAIL as expected —
/// `attachment` comes back non-nil. This is the crash-free way to
/// perturb this guard; see the doc comment on the sibling test above for
/// why the "message does not exist" case isn't mutated the same way.
@Test func setAttachmentLocalFilenameIsANoOpWhenTheMessageHasNoAttachment() async throws {
    let (store, context, serverID) = try makeSearchStore()
    insertMessage(context, serverID: serverID, id: "a", time: 100, body: "a")
    try context.save()
    let key = Message.uniqueKey(serverID: serverID, topic: "alerts", messageID: "a")

    try await store.setAttachmentLocalFilename("a1b2c3.png", forMessage: key)
    let messages = try await store.messages(forServer: serverID, topic: nil, limit: 10)
    #expect(messages.first?.attachment == nil)
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

    try await store.removeServer(serverID, attachmentsDirectory: nil)
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
    try await store.removeServer(removedID, attachmentsDirectory: nil)

    #expect(try await store.messageCount() == 1)
    let remaining = try await store.messages(forServer: keptID, topic: nil, limit: 10)
    #expect(remaining.map(\.body) == ["b"])
}

@Test func removeServerAlsoRemovesItsSubscriptions() async throws {
    let (store, _, serverID) = try makeSearchStore()
    try await store.removeServer(serverID, attachmentsDirectory: nil)
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
