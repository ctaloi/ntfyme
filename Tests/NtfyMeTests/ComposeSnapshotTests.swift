import AppKit
import SwiftData
import SwiftUI
import Testing
import NtfyKit
@testable import NtfyMe

/// Headless renders of the Compose window, for visual review. Like
/// `HistorySnapshotTests`, every server and topic below is invented — this
/// repository is public.

/// This file's own floors rather than `HistorySnapshotTests`' (which are
/// private to it, and calibrated for a surface with far more colour in it).
/// Both are set well below what a real render of this window measures and
/// well above what a broken one does — see the note beside each.
///
/// A blank surface measures 1 colour; this window is mostly text fields and
/// labels on one background, so its real renders sit far lower than the
/// History detail pane's 60-odd.
private let composeMinimumColors = 12
/// An unpainted background is what `.settingsBackground()` exists to
/// prevent, and what the History views were caught without twice. A fully
/// painted surface measures ~1.0.
private let composeMinimumMeanAlpha = 0.85

@MainActor
private func makeComposeModel(topics: [String]) throws -> ComposeModel {
    let container = try ModelContainer(
        for: Server.self, Subscription.self, Message.self, Attachment.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let context = ModelContext(container)
    let server = Server(name: "ntfy.sh", baseURLString: "https://ntfy.sh", sortOrder: 0)
    context.insert(server)
    let office = Server(name: "Office", baseURLString: "https://ntfy.office.example", sortOrder: 1)
    context.insert(office)
    topics.forEach { context.insert(Subscription(topic: $0, server: server)) }
    try context.save()

    return ComposeModel(
        store: MessageStore(modelContainer: container),
        keychain: KeychainStore(service: "dev.aloi.NtfyMe.composeSnapshots.\(UUID().uuidString)"),
        publish: { _, _, _ in })
}

@MainActor
@Test(requiresSnapshotRendering) func composeEmpty() async throws {
    let model = try makeComposeModel(topics: ["alerts", "deploys", "backups"])
    await model.refresh()

    _ = try renderSnapshot(ComposeView(model: model),
                           size: CGSize(width: 460, height: 520), to: "compose-empty.png")
    let colors = try distinctColorCount(ofPNGAt: "/tmp/ntfyshots/compose-empty.png")
    #expect(colors > composeMinimumColors)
    let alpha = try meanAlpha(ofPNGAt: "/tmp/ntfyshots/compose-empty.png")
    #expect(alpha > composeMinimumMeanAlpha)
}

@MainActor
@Test(requiresSnapshotRendering) func composeFilledIn() async throws {
    let model = try makeComposeModel(topics: ["alerts", "deploys"])
    await model.refresh()
    model.draft.topic = "deploys"
    model.draft.title = "Deploy failed: web-03"
    model.draft.body = "Build #482 failed on web-03.\nExit code: 137"
    model.draft.priority = .high
    model.tagText = "warning, rocket"

    _ = try renderSnapshot(ComposeView(model: model),
                           size: CGSize(width: 460, height: 520), to: "compose-filled.png")
    #expect(try distinctColorCount(ofPNGAt: "/tmp/ntfyshots/compose-filled.png") > composeMinimumColors)
}

/// The failure state, which is the one that matters most on this surface: a
/// send that failed must show why *and* still have the message in it.
@MainActor
@Test(requiresSnapshotRendering) func composeAfterAFailedSend() async throws {
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
        keychain: KeychainStore(service: "dev.aloi.NtfyMe.composeSnapshots.\(UUID().uuidString)"),
        publish: { _, _, _ in throw NtfyPublisher.Error.notAuthorized })
    await model.refresh()
    model.draft.title = "Deploy failed: web-03"
    model.draft.body = "Build #482 failed on web-03."
    await model.send()

    #expect(model.draft.body.isEmpty == false, "a failed send must keep the message")

    _ = try renderSnapshot(ComposeView(model: model),
                           size: CGSize(width: 460, height: 520), to: "compose-error.png")
    #expect(try distinctColorCount(ofPNGAt: "/tmp/ntfyshots/compose-error.png") > composeMinimumColors)
}

@MainActor
@Test(requiresSnapshotRendering) func composeDarkMode() async throws {
    let model = try makeComposeModel(topics: ["alerts", "deploys"])
    await model.refresh()
    model.draft.topic = "alerts"
    model.draft.body = "Nightly backup finished."

    _ = try renderSnapshot(ComposeView(model: model),
                           size: CGSize(width: 460, height: 520), colorScheme: .dark,
                           to: "compose-dark.png")
    // Same check the History detail pane needed: every colour on this
    // surface is dynamic, so an unpainted background renders as light text
    // on nothing under `.dark`.
    #expect(try meanAlpha(ofPNGAt: "/tmp/ntfyshots/compose-dark.png") > composeMinimumMeanAlpha)
}
