import Foundation
import SwiftData
import Testing
@testable import NtfyKit

@Test func theStoreReportsItsServersAsSendableSnapshots() async throws {
    let container = try StoreFixtures.inMemoryContainer()
    let context = ModelContext(container)
    let a = Server(name: "Alpha", baseURLString: "https://a.example.com", sortOrder: 1)
    let b = Server(name: "Beta", baseURLString: "https://b.example.com", sortOrder: 0)
    context.insert(a); context.insert(b)
    context.insert(Subscription(topic: "alerts", server: a,
                                lastMessageTime: Date(timeIntervalSince1970: 100)))
    context.insert(Subscription(topic: "deploys", server: a))
    try context.save()

    let store = MessageStore(modelContainer: container)
    let servers = try await store.servers()

    #expect(servers.map(\.name) == ["Beta", "Alpha"])          // sortOrder, not insertion
    let alpha = try #require(servers.first { $0.name == "Alpha" })
    #expect(alpha.baseURL == URL(string: "https://a.example.com"))
    #expect(Set(alpha.topics) == ["alerts", "deploys"])
    #expect(alpha.watermarks.first { $0.topic == "alerts" }?.lastMessageTime
            == Date(timeIntervalSince1970: 100))
    #expect(alpha.watermarks.first { $0.topic == "deploys" }?.lastMessageTime == nil)
}

/// caughtUpTo must survive the round trip, or a restart replays every quiet
/// topic's whole cache — the defect Stage 3 exists to remove.
@Test func aServerSnapshotCarriesItsPersistedCaughtUpTo() async throws {
    let container = try StoreFixtures.inMemoryContainer()
    let id = UUID()
    let context = ModelContext(container)
    let server = Server(id: id, name: "Alpha", baseURLString: "https://a.example.com")
    context.insert(server)
    context.insert(Subscription(topic: "alerts", server: server))
    try context.save()

    let store = MessageStore(modelContainer: container)
    let mark = Date(timeIntervalSince1970: 1_788_353_322)
    try await store.setCaughtUpTo(mark, forServer: id)

    let snapshot = try #require(try await store.servers().first)
    #expect(snapshot.caughtUpTo == mark)
}

/// A server with a malformed URL is a corrupt row, not a crash.
@Test func aServerWithAnUnparseableURLIsSkippedNotFatal() async throws {
    let container = try StoreFixtures.inMemoryContainer()
    let context = ModelContext(container)
    context.insert(Server(name: "Broken", baseURLString: ""))
    let ok = Server(name: "Fine", baseURLString: "https://a.example.com")
    context.insert(ok)
    context.insert(Subscription(topic: "alerts", server: ok))
    try context.save()

    let servers = try await MessageStore(modelContainer: container).servers()
    #expect(servers.map(\.name) == ["Fine"])
}
