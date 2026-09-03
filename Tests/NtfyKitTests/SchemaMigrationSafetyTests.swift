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
