import Foundation
import SwiftData
import Testing
@testable import NtfyKit

/// This app ships no `VersionedSchema` and no `SchemaMigrationPlan`, so every
/// schema change relies on Core Data's lightweight migration.
///
/// Lightweight migration **cannot** add a non-optional attribute that has no
/// default value. It fails the store open outright:
///
///     Cannot migrate store in-place: Validation error missing attribute
///     values on mandatory destination attribute
///     entity=Message, attribute=tagsJoined
///
/// `AppGraph.init()` then throws and the user's entire archive is unreachable
/// — not a degraded feature, a bricked app. This was measured against a store
/// written by the previous schema with rows in it, not reasoned about.
///
/// **The rule for anyone adding an attribute:** an attribute added after the
/// first shipped schema must be either optional or given a default. The
/// attributes that predate any released build (`uniqueKey`, `body`, `time`
/// and friends) legitimately have neither, because no store has ever existed
/// without them — which is why this file pins the added ones by name rather
/// than asserting a blanket rule that would be wrong.
@Test func attributesAddedAfterTheFirstSchemaCarryADefault() throws {
    let schema = Schema([Server.self, Subscription.self, Message.self, Attachment.self])

    // Every attribute added to a shipped entity since the first schema.
    // Add to this list when you add an attribute; do not delete from it.
    let addedSinceFirstSchema: [(entity: String, attribute: String)] = [
        ("Message", "tagsJoined"),
    ]

    for (entityName, attributeName) in addedSinceFirstSchema {
        let entity = try #require(
            schema.entities.first { $0.name == entityName },
            "no entity named \(entityName) in the schema")
        let attribute = try #require(
            entity.attributes.first { $0.name == attributeName },
            "no attribute \(entityName).\(attributeName) in the schema")

        // Optional is equally safe — lightweight migration fills it with nil.
        #expect(attribute.isOptional || attribute.defaultValue != nil,
                "\(entityName).\(attributeName) is non-optional with no default. Lightweight migration cannot add it, so upgrading a store written by an earlier build will fail to open and the archive becomes unreachable.")
    }
}


/// The durable form of the guard above: open a store that was genuinely
/// written by an earlier schema, with rows in it, using today's schema.
///
/// This exists because the named-attribute test has the same failure class as
/// the bug it guards — a list only covers what someone remembered to add, so
/// the first attribute added without a default would pass it silently. This
/// test needs no list. Any schema change lightweight migration cannot infer
/// fails it automatically.
///
/// `Fixtures/PreTagsJoined.store` was generated from the commit before
/// `tagsJoined` was introduced, seeded with three `Message` rows through the
/// real store API, then checkpointed and vacuumed into a single file. **Rows
/// are the point.** An empty store migrates cleanly even when a mandatory
/// attribute has no default — validation has nothing to validate — so a
/// fixture without rows would report a false clean. That is exactly the trap
/// that nearly let this bug through: the store on the development machine
/// migrated fine because it happened to be empty.
@Test func aStoreFromTheEarlierSchemaStillOpens() async throws {
    let fixture = try #require(
        Bundle.module.url(forResource: "PreTagsJoined", withExtension: "store",
                          subdirectory: "Fixtures"),
        "the pre-migration fixture is missing from the test bundle")

    // Copied because opening migrates in place, and a fixture that mutates
    // itself only tests the upgrade once.
    let directory = URL(filePath: NSTemporaryDirectory())
        .appending(path: "migration-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let working = directory.appending(path: "PreTagsJoined.store")
    try FileManager.default.copyItem(at: fixture, to: working)

    let container = try ModelContainer(
        for: Server.self, Subscription.self, Message.self, Attachment.self,
        configurations: ModelConfiguration(url: working))
    let store = MessageStore(modelContainer: container)

    // The rows survive the upgrade — the archive is not lost.
    let all = try await store.search(MessageQuery(limit: 100))
    #expect(all.count == 3)

    // And they are readable, not just countable.
    #expect(all.contains { $0.body == "fixture body 1" })
}
