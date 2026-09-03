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

// MARK: - Notification authorization

@MainActor @Test func refreshNotificationAuthorizationReadsTheSuppliedStatus() async throws {
    let container = try ModelContainer(
        for: Server.self, Subscription.self, Message.self, Attachment.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let store = MessageStore(modelContainer: container)
    let defaults = UserDefaults(suiteName: "dev.aloi.NtfyMe.modelTests.\(UUID().uuidString)")!
    let model = SettingsModel(
        store: store, preferences: PreferencesStore(defaults: defaults),
        keychain: KeychainStore(service: "dev.aloi.NtfyMe.modelTests.\(UUID().uuidString)"),
        defaults: defaults,
        notificationAuthorizationStatus: { .denied })

    #expect(model.notificationAuthorization == .notDetermined)
    await model.refreshNotificationAuthorization()
    #expect(model.notificationAuthorization == .denied)
}

/// `enableNotifications()` is the Notifications tab's "ask now" action for a
/// not-yet-determined status — it must both call the request closure and
/// leave the model holding whatever the system answered, not the stale
/// pre-request status.
@MainActor @Test func enableNotificationsRequestsAndThenRefreshes() async throws {
    let container = try ModelContainer(
        for: Server.self, Subscription.self, Message.self, Attachment.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let store = MessageStore(modelContainer: container)
    let defaults = UserDefaults(suiteName: "dev.aloi.NtfyMe.modelTests.\(UUID().uuidString)")!
    // `nonisolated(unsafe)`: both closures below are `@Sendable` by type,
    // but `enableNotifications()` only ever awaits one and then the other
    // on this same `@MainActor` test — never concurrently — so there is no
    // actual data race, just a capture the compiler cannot see is safe
    // without this.
    nonisolated(unsafe) var didRequest = false
    // The request "grants" access; the status closure reflects that only
    // after the request happened, the same way the real system would only
    // report .authorized once the user has actually answered the prompt.
    let model = SettingsModel(
        store: store, preferences: PreferencesStore(defaults: defaults),
        keychain: KeychainStore(service: "dev.aloi.NtfyMe.modelTests.\(UUID().uuidString)"),
        defaults: defaults,
        notificationAuthorizationStatus: { didRequest ? .authorized : .notDetermined },
        requestNotificationAuthorization: {
            didRequest = true
            return true
        })

    await model.enableNotifications()

    #expect(didRequest)
    #expect(model.notificationAuthorization == .authorized)
}

// MARK: - Store change notification

/// The first bug this hook fixed: a user muted/unmuted a topic in Settings
/// and the History window kept showing the old state, because nothing told it
/// the write had happened. Covers both paths through `setAlertSettings` —
/// mute and minimum priority both call it.
@MainActor @Test func setAlertSettingsNotifiesOnSuccessForBothMuteAndPriority() async throws {
    let container = try ModelContainer(
        for: Server.self, Subscription.self, Message.self, Attachment.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let store = MessageStore(modelContainer: container)
    let defaults = UserDefaults(suiteName: "dev.aloi.NtfyMe.modelTests.\(UUID().uuidString)")!
    // See `enableNotificationsRequestsAndThenRefreshes` for why
    // `nonisolated(unsafe)` is safe here: this model's calls are awaited
    // one at a time on this same `@MainActor` test, never concurrently.
    nonisolated(unsafe) var notifiedCount = 0
    let model = SettingsModel(
        store: store, preferences: PreferencesStore(defaults: defaults),
        keychain: KeychainStore(service: "dev.aloi.NtfyMe.modelTests.\(UUID().uuidString)"),
        defaults: defaults,
        onStoreChanged: { notifiedCount += 1 })

    let serverID = try await store.addServer(
        name: "ntfy.sh", baseURL: URL(string: "https://ntfy.sh")!, authKindRaw: "unauthenticated")
    try await store.addTopic("alerts", toServer: serverID)

    // Success: mute.
    await model.setAlertSettings(TopicAlertSettings(muted: true, minAlertPriority: 1),
                                 serverID: serverID, topic: "alerts")
    #expect(notifiedCount == 1)

    // Success: minimum priority, a different field through the same call.
    await model.setAlertSettings(TopicAlertSettings(muted: true, minAlertPriority: 4),
                                 serverID: serverID, topic: "alerts")
    #expect(notifiedCount == 2)

    // Not tested here: the genuine-failure path (a throwing modelContext
    // .save()). MessageStore.setAlertSettings only throws on a save
    // failure — an unknown server or topic logs and returns instead (see
    // its doc comment), which is not an error `SettingsModel` can
    // distinguish from success, so it is not a useful case to assert on
    // here. Forcing a real save failure needs the on-disk,
    // permissions-revoked setup `MessageStoreTests.swift` already uses for
    // exactly this reason — not worth repeating for one more call site.
}

/// The second bug, and the reason the hook covers *every* write rather than
/// the one store method it started on: a topic added in Settings never
/// appeared in the History sidebar, because `setAlertSettings` was the only
/// path that posted. Pins each remaining write that changes what another
/// surface displays.
///
/// `addServer` is deliberately absent: its success path saves a credential to
/// the real Keychain, which no other test in this file does, and it posts
/// from the same `await onStoreChanged()` line the others do.
@MainActor @Test func everyTopicWriteNotifiesNotJustAlertSettings() async throws {
    let container = try ModelContainer(
        for: Server.self, Subscription.self, Message.self, Attachment.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let store = MessageStore(modelContainer: container)
    let defaults = UserDefaults(suiteName: "dev.aloi.NtfyMe.modelTests.\(UUID().uuidString)")!
    // `nonisolated(unsafe)`: see the sibling test above.
    nonisolated(unsafe) var notifiedCount = 0
    let model = SettingsModel(
        store: store, preferences: PreferencesStore(defaults: defaults),
        keychain: KeychainStore(service: "dev.aloi.NtfyMe.modelTests.\(UUID().uuidString)"),
        defaults: defaults,
        onStoreChanged: { notifiedCount += 1 })

    let serverID = try await store.addServer(
        name: "ntfy.sh", baseURL: URL(string: "https://ntfy.sh")!, authKindRaw: "unauthenticated")

    await model.addTopic("telescope", toServer: serverID)
    #expect(notifiedCount == 1)
    #expect(model.errorMessage == nil)

    await model.removeTopic("telescope", fromServer: serverID)
    #expect(notifiedCount == 2)

    // A "clear data" that leaves other surfaces listing the messages it just
    // deleted is the same bug pointed the other way.
    await model.clearAllMessages()
    #expect(notifiedCount == 3)

    await model.removeServer(serverID)
    #expect(notifiedCount == 4)
}

// MARK: - Subscription import/export

/// The transfer file round-trips, and the decoder rejects everything it
/// should: wrong version, invalid topic, unusable server URL, out-of-range
/// priority, and duplicate rows (deduped rather than shown twice).
@MainActor @Test func transferFileRoundTripAndValidation() throws {
    let originals: [SubscriptionTransfer] = [
        SubscriptionTransfer(server: "https://ntfy.sh", topic: "alerts",
                             displayName: nil, muted: false, minAlertPriority: 3),
        SubscriptionTransfer(server: "HTTPS://NTFY.Example.com/", topic: "deploys",
                             displayName: "Deploys", muted: true, minAlertPriority: 4),
    ]

    let data = try SubscriptionsTransferCodec.encode(originals)
    let decoded = try SubscriptionsTransferCodec.decode(data)

    // URLs normalized on the way through, so an independently-typed copy
    // of the same server matches on import.
    #expect(decoded.count == 2)
    #expect(decoded[0].server == "https://ntfy.sh")
    #expect(decoded[1].server == "https://ntfy.example.com")
    #expect(decoded[1].topic == "deploys")
    #expect(decoded[1].muted)
}

@Test func transferDecoderRejectsBadFiles() throws {
    func fileJSON(_ body: String) -> Data {
        Data("""
        {"version":1,"subscriptions":[\(body)]}
        """.utf8)
    }

    #expect(throws: DecodingError.self) {
        try SubscriptionsTransferCodec.decode(Data("""
        {"version":99,"subscriptions":[]}
        """.utf8))
    }
    #expect(throws: DecodingError.self) {
        try SubscriptionsTransferCodec.decode(fileJSON(
            #"{"server":"https://ntfy.sh","topic":"has spaces","muted":false,"minAlertPriority":1}"#))
    }
    #expect(throws: DecodingError.self) {
        try SubscriptionsTransferCodec.decode(fileJSON(
            #"{"server":"ftp://x.example","topic":"ok","muted":false,"minAlertPriority":1}"#))
    }
    #expect(throws: DecodingError.self) {
        try SubscriptionsTransferCodec.decode(fileJSON(
            #"{"server":"https://ntfy.sh","topic":"ok","muted":false,"minAlertPriority":9}"#))
    }
    // A valid duplicate row is deduped, not doubled.
    let duplicated = try SubscriptionsTransferCodec.decode(fileJSON(
        #"{"server":"https://ntfy.sh","topic":"alerts","muted":false,"minAlertPriority":1},"# +
        #"{"server":"https://ntfy.sh","topic":"alerts","muted":false,"minAlertPriority":1}"#))
    #expect(duplicated.count == 1)
}

/// Importing against a store that already follows one of the file's topics:
/// the new server is created without a credential, the known topic is
/// skipped, and the new topic arrives with the file's alert settings —
/// not the default `addTopic` would have seeded.
@MainActor @Test func importingSkipsKnownTopicsAndCarriesSettings() async throws {
    let (store, model) = try makeModel()
    await model.seedDefaultServerIfNeeded()
    // The seed arrives with no topics; "alerts" here is something this
    // machine already follows, which the seed alone does not give us.
    let seededID = try #require(try await store.servers().first?.id)
    try await store.addTopic("alerts", toServer: seededID)

    let outcome = await model.importSubscriptions([
        // Already followed on the seeded ntfy.sh.
        SubscriptionTransfer(server: "https://ntfy.sh", topic: "alerts",
                             displayName: nil, muted: false, minAlertPriority: 3),
        // New topic on the known server, with non-default settings.
        SubscriptionTransfer(server: "https://ntfy.sh", topic: "deploys",
                             displayName: "Deploys", muted: true, minAlertPriority: 4),
        // A server this machine has never seen. Its host becomes the name.
        SubscriptionTransfer(server: "https://office.example.com", topic: "builds",
                             displayName: nil, muted: false, minAlertPriority: 1),
    ])

    #expect(outcome.imported == 2)
    #expect(outcome.skipped == 1)
    #expect(outcome.failed == 0)

    let servers = try await store.servers()
    #expect(servers.count == 2, "the unknown server was created")
    let office = try #require(servers.first { $0.baseURL.host == "office.example.com" })
    #expect(office.name == "office.example.com")
    #expect(office.authKindRaw == SettingsCredentialKind.unauthenticated.rawValue)

    let ntfySh = try #require(servers.first { $0.baseURL.host == "ntfy.sh" })
    let deploys = try await store.alertSettings(forServer: ntfySh.id, topic: "deploys")
    #expect(deploys.muted == true)
    #expect(deploys.minAlertPriority == 4)

    // Importing the same file again skips everything — the idempotence the
    // "skipped" column exists to express.
    let again = await model.importSubscriptions([
        SubscriptionTransfer(server: "https://ntfy.sh", topic: "alerts",
                             displayName: nil, muted: false, minAlertPriority: 3),
        SubscriptionTransfer(server: "https://ntfy.sh", topic: "deploys",
                             displayName: "Deploys", muted: true, minAlertPriority: 4),
        SubscriptionTransfer(server: "https://office.example.com", topic: "builds",
                             displayName: nil, muted: false, minAlertPriority: 1),
    ])
    #expect(again.imported == 0)
    #expect(again.skipped == 3)
}
