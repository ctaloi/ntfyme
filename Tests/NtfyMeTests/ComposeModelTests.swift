import Foundation
import SwiftData
import Testing
import NtfyKit
@testable import NtfyMe

/// `ComposeModel` with a stubbed publish closure — no network, no window.
/// The happy path matters least here: what matters is that every failure
/// says something specific and, above all, that a failed send does not throw
/// away the message the user typed.

@MainActor
private func makeModel(
    publish: @escaping @Sendable (MessageDraft, URL, AuthCredential) async throws -> Void
) throws -> (model: ComposeModel, serverID: UUID) {
    let container = try ModelContainer(
        for: Server.self, Subscription.self, Message.self, Attachment.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let context = ModelContext(container)
    let server = Server(name: "ntfy.sh", baseURLString: "https://ntfy.sh", sortOrder: 0)
    context.insert(server)
    context.insert(Subscription(topic: "alerts", server: server))
    context.insert(Subscription(topic: "deploys", server: server))
    try context.save()

    let model = ComposeModel(
        store: MessageStore(modelContainer: container),
        // Unique service per run so a leftover Keychain item cannot decide a
        // test — same isolation `SettingsModelTests` uses.
        keychain: KeychainStore(service: "dev.aloi.NtfyMe.composeTests.\(UUID().uuidString)"),
        publish: publish)
    return (model, server.id)
}

/// A recorder for what the publish closure was handed. `nonisolated(unsafe)`
/// is safe for the same reason it is in `SettingsModelTests`: every call
/// below is awaited one at a time from this same `@MainActor` test.
private final class Recorder: @unchecked Sendable {
    var drafts: [MessageDraft] = []
    var urls: [URL] = []
    var credentials: [AuthCredential] = []
}

// MARK: - Loading and defaults

@MainActor @Test func refreshSelectsTheOnlyServer() async throws {
    let (model, serverID) = try makeModel { _, _, _ in }
    await model.refresh()

    #expect(model.selectedServerID == serverID)
    #expect(model.servers.count == 1)
    #expect(model.topicSuggestions == ["alerts", "deploys"])
}

/// Two subscribed topics means no prefill: this button publishes to whatever
/// is in the field, and a plausible-looking guess is the wrong kind of
/// convenience for that.
@MainActor @Test func twoTopicsMeansNoPrefilledTopic() async throws {
    let (model, _) = try makeModel { _, _, _ in }
    await model.refresh()

    #expect(model.draft.topic.isEmpty)
    #expect(model.canSend == false)
}

/// One subscribed topic is unambiguous, so it is filled in.
@MainActor @Test func aSingleTopicIsPrefilled() async throws {
    let container = try ModelContainer(
        for: Server.self, Subscription.self, Message.self, Attachment.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let context = ModelContext(container)
    let server = Server(name: "ntfy.sh", baseURLString: "https://ntfy.sh", sortOrder: 0)
    context.insert(server)
    context.insert(Subscription(topic: "alerts", server: server))
    try context.save()

    let model = ComposeModel(
        store: MessageStore(modelContainer: container),
        keychain: KeychainStore(service: "dev.aloi.NtfyMe.composeTests.\(UUID().uuidString)"),
        publish: { _, _, _ in })
    await model.refresh()

    #expect(model.draft.topic == "alerts")
}

/// A refresh must not overwrite a destination the user has already chosen —
/// `ComposeView` calls it from `.task`, which runs again when the window is
/// rebuilt.
@MainActor @Test func refreshKeepsAServerTheUserAlreadyPicked() async throws {
    let (model, serverID) = try makeModel { _, _, _ in }
    await model.refresh()
    model.draft.topic = "hand-typed"

    await model.refresh()

    #expect(model.selectedServerID == serverID)
    #expect(model.draft.topic == "hand-typed")
}

// MARK: - canSend

@MainActor @Test func sendNeedsAServerATopicAndABody() async throws {
    let (model, serverID) = try makeModel { _, _, _ in }
    await model.refresh()
    #expect(model.canSend == false)

    model.draft.topic = "alerts"
    #expect(model.canSend == false, "a topic with no body is not a message")

    model.draft.body = "hello"
    #expect(model.canSend == true)

    // ntfy accepts a message with no title, so a title is never required.
    #expect(model.draft.title == nil)

    model.selectedServerID = nil
    #expect(model.canSend == false)
    model.selectedServerID = serverID

    // Whitespace is not a body.
    model.draft.body = "   \n  "
    #expect(model.canSend == false)
}

// MARK: - Tags

@MainActor @Test func theTagFieldParsesIntoTheDraft() async throws {
    let (model, _) = try makeModel { _, _, _ in }

    model.tagText = "warning, skull,  , rocket"

    // Trimmed, empties dropped, order kept.
    #expect(model.draft.tags == ["warning", "skull", "rocket"])
}

// MARK: - Sending

@MainActor @Test func aSuccessfulSendPublishesTheDraftAndClearsTheMessage() async throws {
    let recorder = Recorder()
    let (model, _) = try makeModel { draft, url, credential in
        recorder.drafts.append(draft)
        recorder.urls.append(url)
        recorder.credentials.append(credential)
    }
    await model.refresh()
    model.draft.topic = "alerts"
    model.draft.title = "Deploy failed"
    model.draft.body = "web-03 is down"
    model.draft.priority = .high
    model.tagText = "warning"

    await model.send()

    #expect(recorder.drafts.count == 1)
    #expect(recorder.drafts[0] == MessageDraft(
        topic: "alerts", title: "Deploy failed", body: "web-03 is down",
        priority: .high, tags: ["warning"]))
    #expect(recorder.urls[0] == URL(string: "https://ntfy.sh")!)
    // No credential was ever saved for this server, and `KeychainStore.load`
    // answers `errSecItemNotFound` with `.unauthenticated` rather than
    // throwing — the same thing the seeded ntfy.sh server relies on.
    #expect(recorder.credentials[0] == .unauthenticated)

    #expect(model.errorMessage == nil)
    #expect(model.lastSentSummary == "Sent to alerts")
    // The message is gone so it cannot be sent twice; the destination and
    // priority survive, because sending several to one topic is the case.
    #expect(model.draft.body.isEmpty)
    #expect(model.draft.title == nil)
    #expect(model.draft.tags.isEmpty)
    #expect(model.tagText.isEmpty)
    #expect(model.draft.topic == "alerts")
    #expect(model.draft.priority == .high)
}

/// The one that matters most: losing a typed message to a rate limit would
/// be worse than the rate limit.
@MainActor @Test func aFailedSendKeepsTheWholeDraft() async throws {
    let (model, _) = try makeModel { _, _, _ in throw NtfyPublisher.Error.rateLimited }
    await model.refresh()
    model.draft.topic = "alerts"
    model.draft.title = "Deploy failed"
    model.draft.body = "web-03 is down"
    model.tagText = "warning"

    await model.send()

    #expect(model.errorMessage?.contains("rate-limiting") == true)
    #expect(model.lastSentSummary == nil)
    #expect(model.draft.title == "Deploy failed")
    #expect(model.draft.body == "web-03 is down")
    #expect(model.draft.tags == ["warning"])
    #expect(model.tagText == "warning")
    // And it can be retried without retyping anything.
    #expect(model.canSend == true)
}

@MainActor @Test func everyPublishErrorGetsItsOwnSentence() async throws {
    let errors: [NtfyPublisher.Error] = [
        .notAuthorized, .topicRejected, .tooLarge, .rateLimited,
        .unexpectedStatus(500), .notAnHTTPResponse,
    ]
    var seen: Set<String> = []
    for error in errors {
        let message = ComposeModel.message(for: error)
        #expect(!message.isEmpty)
        // Distinct, not just present: two failures sharing one sentence
        // means the user cannot tell them apart, which is the whole point of
        // the typed error.
        #expect(seen.insert(message).inserted, "duplicate message for \(error)")
        // No server-supplied text and no URL reaches the user (spec §9).
        #expect(!message.contains("ntfy.sh"))
    }
    #expect(ComposeModel.message(for: .unexpectedStatus(503)).contains("503"))
}

/// A transport failure is not a `NtfyPublisher.Error` — it propagates as a
/// `URLError` — so it takes the `catch`-all branch and has to say something
/// useful rather than falling through as a silent no-op.
@MainActor @Test func aTransportFailureSaysTheServerCouldNotBeReached() async throws {
    let (model, _) = try makeModel { _, _, _ in
        throw URLError(.notConnectedToInternet)
    }
    await model.refresh()
    model.draft.topic = "alerts"
    model.draft.body = "hello"

    await model.send()

    #expect(model.errorMessage == "Couldn't reach the server.")
    #expect(model.draft.body == "hello")
}

/// An invalid topic surfaces `NtfyEndpoint`'s own error, since publishing
/// runs the same validation streaming does.
@MainActor @Test func anInvalidTopicSaysWhatIsAllowed() async throws {
    let (model, _) = try makeModel { _, _, _ in
        throw NtfyEndpoint.Error.invalidTopic("has spaces")
    }
    await model.refresh()
    model.draft.topic = "has spaces"
    model.draft.body = "hello"

    await model.send()

    #expect(model.errorMessage?.contains("isn't valid") == true)
    // Does not echo the topic back — it is the one thing already on screen.
    #expect(model.errorMessage?.contains("has spaces") == false)
}

/// Nothing is published for a draft that is not sendable, even if `send()`
/// is reached some way other than the (disabled) button — a keyboard
/// shortcut, say.
@MainActor @Test func sendIsANoOpForAnIncompleteDraft() async throws {
    let recorder = Recorder()
    let (model, _) = try makeModel { draft, _, _ in recorder.drafts.append(draft) }
    await model.refresh()
    model.draft.topic = "alerts"
    // No body.

    await model.send()

    #expect(recorder.drafts.isEmpty)
    #expect(model.errorMessage == nil, "not an error — just nothing to send yet")
}

/// A server removed in Settings between opening the window and pressing Send
/// fails with something the user can act on, rather than publishing nowhere.
@MainActor @Test func aVanishedServerIsReportedRatherThanIgnored() async throws {
    let recorder = Recorder()
    let (model, _) = try makeModel { draft, _, _ in recorder.drafts.append(draft) }
    await model.refresh()
    model.draft.topic = "alerts"
    model.draft.body = "hello"
    model.selectedServerID = UUID()   // no longer in `servers`

    await model.send()

    #expect(recorder.drafts.isEmpty)
    #expect(model.errorMessage == "That server is no longer configured.")
    #expect(model.draft.body == "hello")
}
