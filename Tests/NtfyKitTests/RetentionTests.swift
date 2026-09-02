import Foundation
import SwiftData
import Testing
@testable import NtfyKit

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func event(_ id: String, topic: String = "alerts", ageDays: Double) -> NtfyEvent {
    let t = Int(now.addingTimeInterval(-ageDays * 86_400).timeIntervalSince1970)
    let json = """
    {"id":"\(id)","time":\(t),"event":"message","topic":"\(topic)","message":"m"}
    """
    return try! JSONDecoder().decode(NtfyEvent.self, from: Data(json.utf8))
}

private func makeStore() throws -> (MessageStore, UUID) {
    let container = try StoreFixtures.inMemoryContainer()
    let serverID = UUID()
    let context = ModelContext(container)
    let server = Server(id: serverID, name: "Example", baseURLString: "https://ntfy.example.com")
    context.insert(server)
    context.insert(Subscription(topic: "alerts", server: server))
    try context.save()
    return (MessageStore(modelContainer: container), serverID)
}

@Test func pruningRemovesMessagesOlderThanMaxAge() async throws {
    let (store, serverID) = try makeStore()
    _ = try await store.insert([event("old", ageDays: 40), event("new", ageDays: 1)],
                               serverID: serverID)
    let result = try await store.prune(
        policy: RetentionPolicy(maxAge: 30 * 86_400, maxMessagesPerTopic: 10_000),
        now: now, attachmentsDirectory: nil)
    #expect(result.messagesDeleted == 1)
    #expect(try await store.messageCount() == 1)
    let left = try await store.messages(forServer: serverID, topic: nil, limit: 10)
    #expect(left.first?.messageID == "new")
}

@Test func pruningKeepsAtMostMaxMessagesPerTopicNewestFirst() async throws {
    let (store, serverID) = try makeStore()
    let events = (0..<10).map { event("m\($0)", ageDays: Double(10 - $0) * 0.1) }
    _ = try await store.insert(events, serverID: serverID)

    let result = try await store.prune(
        policy: RetentionPolicy(maxAge: 30 * 86_400, maxMessagesPerTopic: 4),
        now: now, attachmentsDirectory: nil)
    #expect(result.messagesDeleted == 6)
    #expect(try await store.messageCount() == 4)
}

/// The per-topic cap is PER TOPIC, not global.
@Test func theCountCapAppliesPerTopicNotAcrossTopics() async throws {
    let container = try StoreFixtures.inMemoryContainer()
    let serverID = UUID()
    let context = ModelContext(container)
    let server = Server(id: serverID, name: "Example", baseURLString: "https://ntfy.example.com")
    context.insert(server)
    context.insert(Subscription(topic: "alerts", server: server))
    context.insert(Subscription(topic: "deploys", server: server))
    try context.save()
    let store = MessageStore(modelContainer: container)

    _ = try await store.insert((0..<5).map { event("a\($0)", topic: "alerts", ageDays: Double(5 - $0) * 0.1) },
                               serverID: serverID)
    _ = try await store.insert((0..<5).map { event("d\($0)", topic: "deploys", ageDays: Double(5 - $0) * 0.1) },
                               serverID: serverID)

    _ = try await store.prune(policy: RetentionPolicy(maxAge: 30 * 86_400, maxMessagesPerTopic: 3),
                              now: now, attachmentsDirectory: nil)
    #expect(try await store.messageCount() == 6)  // 3 per topic, two topics
}

@Test func nothingIsDeletedWhenEverythingIsWithinPolicy() async throws {
    let (store, serverID) = try makeStore()
    _ = try await store.insert([event("a", ageDays: 1), event("b", ageDays: 2)],
                               serverID: serverID)
    let result = try await store.prune(policy: .default, now: now, attachmentsDirectory: nil)
    #expect(result.messagesDeleted == 0)
    #expect(try await store.messageCount() == 2)
}

/// A pruned message takes its attachment file with it — otherwise the database
/// shrinks and the disk does not.
@Test func pruningDeletesTheAttachmentFileOnDisk() async throws {
    let container = try StoreFixtures.inMemoryContainer()
    let serverID = UUID()
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ntfyme-prune-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let file = dir.appendingPathComponent("graph.png")
    try Data("png".utf8).write(to: file)

    let context = ModelContext(container)
    let server = Server(id: serverID, name: "Example", baseURLString: "https://ntfy.example.com")
    context.insert(server)
    context.insert(Subscription(topic: "alerts", server: server))
    let old = Message(serverID: serverID, topic: "alerts", messageID: "old",
                      time: now.addingTimeInterval(-40 * 86_400), body: "m",
                      attachment: Attachment(name: "graph.png",
                                             urlString: "https://example.com/graph.png",
                                             localFilename: "graph.png"))
    context.insert(old)
    try context.save()

    let store = MessageStore(modelContainer: container)
    let result = try await store.prune(policy: .default, now: now, attachmentsDirectory: dir)
    #expect(result.messagesDeleted == 1)
    #expect(result.attachmentFilesDeleted == 1)
    #expect(FileManager.default.fileExists(atPath: file.path) == false)
}
