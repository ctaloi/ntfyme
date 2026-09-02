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

    let key = "srv/alerts/abc123"
    context.insert(Message(uniqueKey: key, messageID: "abc123", topic: "alerts",
                           serverID: UUID(), time: Date(timeIntervalSince1970: 1),
                           body: "first"))
    try context.save()

    context.insert(Message(uniqueKey: key, messageID: "abc123", topic: "alerts",
                           serverID: UUID(), time: Date(timeIntervalSince1970: 2),
                           body: "second"))
    try context.save()

    let all = try context.fetch(FetchDescriptor<Message>())
    #expect(all.count == 1)
}

/// Records WHICH of the two survives — upsert-last-wins vs keep-first. Task 6
/// must not assume; whichever this reports is what the dedupe is designed for.
@Test func recordsWhichRowSurvivesADuplicateKeyInsert() throws {
    let container = try StoreFixtures.inMemoryContainer()
    let context = ModelContext(container)
    let key = "srv/alerts/dup"

    context.insert(Message(uniqueKey: key, messageID: "dup", topic: "alerts",
                           serverID: UUID(), time: Date(timeIntervalSince1970: 1),
                           body: "first"))
    try context.save()
    context.insert(Message(uniqueKey: key, messageID: "dup", topic: "alerts",
                           serverID: UUID(), time: Date(timeIntervalSince1970: 2),
                           body: "second"))
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

    context.insert(Message(uniqueKey: "srv/alerts/a", messageID: "a", topic: "alerts",
                           serverID: serverID, time: Date(timeIntervalSince1970: 1), body: "a"))
    context.insert(Message(uniqueKey: "srv/alerts/b", messageID: "b", topic: "alerts",
                           serverID: serverID, time: Date(timeIntervalSince1970: 2), body: "b"))
    try context.save()

    #expect(try context.fetch(FetchDescriptor<Message>()).count == 2)
}
