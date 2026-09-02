import Foundation
import SwiftData

/// Minimal shell for the SwiftData duplicate-key probe (Task 4). The full
/// schema — relationships, retention fields, attachment linkage — is Task 5.
@Model
public final class Message {
    @Attribute(.unique) public var uniqueKey: String
    public var messageID: String
    public var topic: String
    public var serverID: UUID
    public var time: Date
    public var body: String

    public init(uniqueKey: String, messageID: String, topic: String,
                serverID: UUID, time: Date, body: String) {
        self.uniqueKey = uniqueKey
        self.messageID = messageID
        self.topic = topic
        self.serverID = serverID
        self.time = time
        self.body = body
    }
}

// Empty shells so the container can be created with the full model set.
// Task 5 replaces these with the real schema.
@Model public final class Server { public var id: UUID; public init(id: UUID) { self.id = id } }
@Model public final class Subscription { public var topic: String; public init(topic: String) { self.topic = topic } }
@Model public final class Attachment { public var name: String; public init(name: String) { self.name = name } }
