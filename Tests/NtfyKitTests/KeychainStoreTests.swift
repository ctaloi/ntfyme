import Foundation
import Testing
@testable import NtfyKit

/// A per-run service name keeps tests from colliding with each other or with a
/// real installed app's keychain items.
private func makeStore() -> KeychainStore {
    KeychainStore(service: "dev.aloi.NtfyMe.tests.\(UUID().uuidString)")
}

@Test func returnsNoneWhenNothingIsStored() throws {
    let store = makeStore()
    #expect(try store.load(forServer: UUID()) == .unauthenticated)
}

@Test func roundTripsABearerToken() throws {
    let store = makeStore()
    let id = UUID()
    try store.save(.bearer(token: "tk_abc123"), forServer: id)
    #expect(try store.load(forServer: id) == .bearer(token: "tk_abc123"))
    try store.delete(forServer: id)
}

@Test func roundTripsBasicCredentials() throws {
    let store = makeStore()
    let id = UUID()
    try store.save(.basic(user: "phil", password: "s3cret"), forServer: id)
    #expect(try store.load(forServer: id) == .basic(user: "phil", password: "s3cret"))
    try store.delete(forServer: id)
}

@Test func savingTwiceOverwritesRatherThanDuplicating() throws {
    let store = makeStore()
    let id = UUID()
    try store.save(.bearer(token: "first"), forServer: id)
    try store.save(.bearer(token: "second"), forServer: id)
    #expect(try store.load(forServer: id) == .bearer(token: "second"))
    try store.delete(forServer: id)
}

@Test func deleteRemovesTheCredential() throws {
    let store = makeStore()
    let id = UUID()
    try store.save(.bearer(token: "tk"), forServer: id)
    try store.delete(forServer: id)
    #expect(try store.load(forServer: id) == .unauthenticated)
}

@Test func deletingSomethingAbsentIsNotAnError() throws {
    let store = makeStore()
    try store.delete(forServer: UUID())
}

@Test func savingNoneClearsAnyStoredCredential() throws {
    let store = makeStore()
    let id = UUID()
    try store.save(.bearer(token: "tk"), forServer: id)
    try store.save(.unauthenticated, forServer: id)
    #expect(try store.load(forServer: id) == .unauthenticated)
}
