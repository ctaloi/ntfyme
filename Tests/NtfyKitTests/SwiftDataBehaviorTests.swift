import Foundation
import SwiftData
import Testing
@testable import NtfyKit

/// These tests document MEASURED SwiftData behavior that Task 6's dedupe
/// depends on. If a toolchain upgrade changes the answer, these fail first
/// and loudly, rather than the ingest path silently duplicating rows.
@Test func insertingTwoRowsWithTheSameUniqueKeyDoesNotProduceTwoRows() throws {
    let container = try StoreFixtures.inMemoryContainer()
    let context = ModelContext(container)

    let serverID = UUID()
    context.insert(Message(serverID: serverID, topic: "alerts", messageID: "abc123",
                           time: Date(timeIntervalSince1970: 1), body: "first"))
    try context.save()

    context.insert(Message(serverID: serverID, topic: "alerts", messageID: "abc123",
                           time: Date(timeIntervalSince1970: 2), body: "second"))
    try context.save()

    let all = try context.fetch(FetchDescriptor<Message>())
    #expect(all.count == 1)
}

/// Records WHICH of the two survives — upsert-last-wins vs keep-first. Task 6
/// must not assume; whichever this reports is what the dedupe is designed for.
@Test func recordsWhichRowSurvivesADuplicateKeyInsert() throws {
    let container = try StoreFixtures.inMemoryContainer()
    let context = ModelContext(container)
    let serverID = UUID()

    context.insert(Message(serverID: serverID, topic: "alerts", messageID: "dup",
                           time: Date(timeIntervalSince1970: 1), body: "first"))
    try context.save()
    context.insert(Message(serverID: serverID, topic: "alerts", messageID: "dup",
                           time: Date(timeIntervalSince1970: 2), body: "second"))
    try context.save()

    let all = try context.fetch(FetchDescriptor<Message>())
    #expect(all.count == 1)
    // Whichever this is, write it into the doc comment on MessageStore.insert.
    #expect(all.first?.body == "second")
}

@Test func differentKeysCoexist() throws {
    let container = try StoreFixtures.inMemoryContainer()
    let context = ModelContext(container)
    let serverID = UUID()

    context.insert(Message(serverID: serverID, topic: "alerts", messageID: "a",
                           time: Date(timeIntervalSince1970: 1), body: "a"))
    context.insert(Message(serverID: serverID, topic: "alerts", messageID: "b",
                           time: Date(timeIntervalSince1970: 2), body: "b"))
    try context.save()

    #expect(try context.fetch(FetchDescriptor<Message>()).count == 2)
}

@Test func uniqueKeyIsComposedOfServerTopicAndMessageID() {
    let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    #expect(Message.uniqueKey(serverID: id, topic: "alerts", messageID: "abc") ==
            "11111111-2222-3333-4444-555555555555/alerts/abc")
}

@Test func deletingAServerCascadesToItsSubscriptions() throws {
    let container = try StoreFixtures.inMemoryContainer()
    let context = ModelContext(container)

    let server = Server(name: "Example", baseURLString: "https://ntfy.example.com")
    let sub = Subscription(topic: "alerts", server: server)
    context.insert(server)
    context.insert(sub)
    try context.save()
    #expect(try context.fetch(FetchDescriptor<Subscription>()).count == 1)

    context.delete(server)
    try context.save()
    #expect(try context.fetch(FetchDescriptor<Subscription>()).isEmpty)
}

@Test func aSnapshotCarriesEverythingTheUiNeedsWithoutTheModelObject() throws {
    let serverID = UUID()
    let message = Message(
        serverID: serverID, topic: "alerts", messageID: "abc",
        time: Date(timeIntervalSince1970: 1_788_353_322),
        title: "Service recovered", body: "**db-01** back to healthy",
        priority: 3, tags: ["white_check_mark"],
        click: "https://example.com/status", iconURL: nil,
        contentType: "text/markdown", actionsJSON: nil
    )
    let snapshot = message.snapshot
    #expect(snapshot.title == "Service recovered")
    #expect(snapshot.isMarkdown == true)
    #expect(snapshot.resolvedPriority == .default)
    #expect(snapshot.tags == ["white_check_mark"])
}
