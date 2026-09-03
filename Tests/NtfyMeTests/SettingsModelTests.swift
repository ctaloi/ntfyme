import Testing
import SwiftData
import Foundation
@testable import NtfyMe
import NtfyKit

/// Behavior tests for `SettingsModel`, as distinct from
/// `SettingsSnapshotTests.swift`'s visual renders — this file asserts what
/// the model actually does, not what it looks like.
///
/// Isolation matches every other fixture in this target: an in-memory
/// `MessageStore`, a `PreferencesStore` and `SettingsModel` both on their own
/// `UserDefaults` suite, a `KeychainStore` on its own service name. Nothing
/// here reads or writes anything real.
@MainActor
private func makeModel() throws -> (store: MessageStore, model: SettingsModel) {
    let container = try ModelContainer(
        for: Server.self, Subscription.self, Message.self, Attachment.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let store = MessageStore(modelContainer: container)
    let defaults = UserDefaults(suiteName: "dev.aloi.NtfyMe.modelTests.\(UUID().uuidString)")!
    let preferences = PreferencesStore(defaults: defaults)
    let keychain = KeychainStore(service: "dev.aloi.NtfyMe.modelTests.\(UUID().uuidString)")
    let model = SettingsModel(store: store, preferences: preferences, keychain: keychain,
                              defaults: defaults)
    return (store, model)
}

@MainActor @Test func seedingAddsNtfyShWithNoTopics() async throws {
    let (store, model) = try makeModel()

    await model.seedDefaultServerIfNeeded()

    let servers = try await store.servers()
    #expect(servers.count == 1)
    let seeded = try #require(servers.first)
    #expect(seeded.name == "ntfy.sh")
    #expect(seeded.baseURL == URL(string: "https://ntfy.sh")!)
    #expect(seeded.authKindRaw == SettingsCredentialKind.unauthenticated.rawValue)
    // The load-bearing property (see `seedDefaultServerIfNeeded`'s doc
    // comment): no topics means `ConnectionCoordinator.sync()` never opens a
    // connection for it, so the seed starts no network activity.
    #expect(seeded.topics.isEmpty)
}

@MainActor @Test func seedingTwiceDoesNotDuplicate() async throws {
    let (store, model) = try makeModel()

    await model.seedDefaultServerIfNeeded()
    await model.seedDefaultServerIfNeeded()

    let servers = try await store.servers()
    #expect(servers.count == 1)
}

/// The behavior the team lead specifically called out: a user who deletes
/// the seeded server must see it stay deleted. Gating on "the server list is
/// empty" would fail this test by re-adding it; gating on the one-time flag
/// (what `seedDefaultServerIfNeeded` actually does) passes it.
@MainActor @Test func deletingTheSeededServerIsRespectedOnNextSeedCall() async throws {
    let (store, model) = try makeModel()

    await model.seedDefaultServerIfNeeded()
    let servers = try await store.servers()
    let seeded = try #require(servers.first)
    // nil: this fixture's ModelContainer is in-memory and never downloads
    // an attachment, so there is provably no file for any directory to name.
    try await store.removeServer(seeded.id, attachmentsDirectory: nil)
    #expect(try await store.servers().isEmpty)

    await model.seedDefaultServerIfNeeded()

    #expect(try await store.servers().isEmpty)
}

/// A server the user added themselves must not suppress or interact with
/// seeding in any way the flag doesn't already govern — seeding is keyed
/// purely on "has this ever run successfully", never on list contents.
@MainActor @Test func seedingIsSkippedOnceFlagIsSetEvenWithOtherServersPresent() async throws {
    let (store, model) = try makeModel()

    await model.seedDefaultServerIfNeeded()
    _ = try await store.addServer(
        name: "Home Lab", baseURL: URL(string: "https://ntfy.example.net")!,
        authKindRaw: "bearer")

    await model.seedDefaultServerIfNeeded()

    let names = Set(try await store.servers().map(\.name))
    #expect(names == ["ntfy.sh", "Home Lab"])
}

/// The upgrade-path regression: an install that already had `https://ntfy.sh`
/// configured by hand — before this method existed, so the flag was never
/// set — must not gain a second row the first time this runs. Every existing
/// install is in exactly this state, which is what made this the case that
/// actually shipped a duplicate rather than a theoretical one; none of the
/// tests above start from a state this method didn't itself create, so none
/// of them could have caught it.
@MainActor @Test func seedingOnAnInstallThatAlreadyHasNtfyShDoesNotDuplicate() async throws {
    let (store, model) = try makeModel()
    _ = try await store.addServer(
        name: "ntfy.sh", baseURL: URL(string: "https://ntfy.sh")!, authKindRaw: "unauthenticated")

    await model.seedDefaultServerIfNeeded()

    let servers = try await store.servers()
    #expect(servers.count == 1)

    // The flag must also end up set — otherwise every future Settings open
    // repeats the `store.servers()` scan against the same already-present row.
    let secondCallServers = try await store.servers()
    await model.seedDefaultServerIfNeeded()
    #expect(try await store.servers().count == secondCallServers.count)
}

/// The base-URL guard compares a normalized form, not raw string equality —
/// a trailing slash or different case is a plausible way a user (or a future
/// hand-typed entry) could already have `https://ntfy.sh` configured.
@MainActor @Test func seedingRecognizesATrailingSlashAndDifferentCaseAsTheSameServer() async throws {
    let (store, model) = try makeModel()
    _ = try await store.addServer(
        name: "ntfy.sh", baseURL: URL(string: "https://NTFY.SH/")!, authKindRaw: "unauthenticated")

    await model.seedDefaultServerIfNeeded()

    #expect(try await store.servers().count == 1)
}
