import Testing
import SwiftUI
import AppKit
import SwiftData
import Foundation
@testable import NtfyMe
import NtfyKit

/// Headless PNG renders of the Settings tabs and the onboarding pane, for
/// visual review only — there is no snapshot-diff harness in this project
/// (see this wave's report). Renders through `renderSnapshot` (see
/// `SnapshotSupport.swift`): a real, offscreen `NSHostingView` in a real,
/// never-ordered-front `NSWindow`, drawn with `cacheDisplay`. `ImageRenderer`
/// was tried first and rejected — it renders `Form(.formStyle(.grouped))`
/// blank and draws every `Button`/`TextField` as a placeholder box, which is
/// nearly everything on this tab's surface.
///
/// Every assertion below checks more than "a file was written": each state
/// asserts a minimum byte count too small to be plausible for empty chrome,
/// and every pair of states that must look different (populated vs. empty,
/// light vs. dark, with vs. without the error alert) asserts their byte
/// counts actually differ. A snapshot test that cannot fail is worse than
/// none — this wave's own History round produced five byte-identical blank
/// renders that each looked like a pass.
///
/// Every fixture below uses placeholder content only — this repository is
/// public: "ntfy.sh" (the real public service, safe to name), "Home Lab" and
/// "Work Notices" as invented server names, `example.net`/`example.org`
/// (IANA-reserved documentation domains, RFC 2606) as their addresses, and
/// generic topic names. No credential value is ever set to anything other
/// than a placeholder string, and no rendered view shows a credential's
/// value at all — the Servers tab only ever displays a credential's *kind*.

/// A fresh, isolated `SettingsModel` plus the exact `MessageStore` it was
/// built with, so a test can seed fixtures through the store's real public
/// API and then have the model reload from that same store. In-memory
/// container (never the user's real database), a `PreferencesStore` on its
/// own `UserDefaults` suite, and a `KeychainStore` on its own service name —
/// the same per-run isolation pattern `KeychainStoreTests`/`PreferencesTests`
/// already use, so this never reads or writes anything real.
@MainActor
private func makeStoreAndModel() throws -> (store: MessageStore, model: SettingsModel) {
    let container = try ModelContainer(
        for: Server.self, Subscription.self, Message.self, Attachment.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let store = MessageStore(modelContainer: container)
    let defaults = UserDefaults(suiteName: "dev.aloi.NtfyMe.snapshotTests.\(UUID().uuidString)")!
    let preferences = PreferencesStore(defaults: defaults)
    let keychain = KeychainStore(service: "dev.aloi.NtfyMe.snapshotTests.\(UUID().uuidString)")
    let model = SettingsModel(store: store, preferences: preferences, keychain: keychain)
    return (store, model)
}

/// Three placeholder servers spanning all three credential kinds and a range
/// of topic counts, added through the real `MessageStore` API — not a mock.
/// Reloads `model` from `store` once seeding is done.
private func seedServers(store: MessageStore, model: SettingsModel) async throws {
    let publicServer = try await store.addServer(
        name: "ntfy.sh", baseURL: URL(string: "https://ntfy.sh")!, authKindRaw: "unauthenticated")
    try await store.addTopic("alerts", toServer: publicServer)
    try await store.addTopic("deploys", toServer: publicServer)

    let homeLab = try await store.addServer(
        name: "Home Lab", baseURL: URL(string: "https://ntfy.example.net")!, authKindRaw: "bearer")
    try await store.addTopic("server-alerts", toServer: homeLab)
    try await store.setAlertSettings(
        TopicAlertSettings(muted: true, minAlertPriority: 3), forServer: homeLab, topic: "server-alerts")

    let work = try await store.addServer(
        name: "Work Notices", baseURL: URL(string: "https://notify.example.org")!, authKindRaw: "basic")
    try await store.addTopic("builds", toServer: work)
    try await store.addTopic("oncall", toServer: work)
    try await store.addTopic("incidents", toServer: work)
    try await store.setAlertSettings(
        TopicAlertSettings(muted: false, minAlertPriority: 4), forServer: work, topic: "incidents")

    await model.loadServers()
}

/// Real sizes — the ones the app actually hosts these views at
/// (`SettingsView`'s `.frame`, and `AppDelegate.presentOnboardingIfNeeded`'s
/// `NSWindow`) — not invented ones.
private let settingsSize = CGSize(width: 520, height: 440)
private let onboardingSize = CGSize(width: 420, height: 340)

/// Below this, a render is almost certainly empty chrome, not real content —
/// every actual tab render in this file comes back well past 10x this.
private let minPlausibleContentBytes = 5_000

@MainActor @Test func renderGeneralTab() async throws {
    let (_, model) = try makeStoreAndModel()
    model.refreshPreferences()
    let bytes = try renderSnapshot(
        SettingsGeneralTab(model: model), size: settingsSize, to: "settings-general.png")
    #expect(bytes > minPlausibleContentBytes)
}

@MainActor @Test func renderServersTabPopulatedAndEmptyDiffer() async throws {
    let (store, populatedModel) = try makeStoreAndModel()
    try await seedServers(store: store, model: populatedModel)
    let populatedBytes = try renderSnapshot(
        SettingsServersTab(model: populatedModel), size: settingsSize,
        to: "settings-servers-populated.png")

    let (_, emptyModel) = try makeStoreAndModel()
    await emptyModel.loadServers()
    let emptyBytes = try renderSnapshot(
        SettingsServersTab(model: emptyModel), size: settingsSize,
        to: "settings-servers-empty.png")

    #expect(populatedBytes > minPlausibleContentBytes)
    #expect(emptyBytes > minPlausibleContentBytes)
    // Three server rows vs. a `ContentUnavailableView` must not coincide.
    #expect(populatedBytes != emptyBytes)
}

@MainActor @Test func renderNotificationsTab() async throws {
    let (_, model) = try makeStoreAndModel()
    model.refreshPreferences()
    let bytes = try renderSnapshot(
        SettingsNotificationsTab(model: model), size: settingsSize, to: "settings-notifications.png")
    #expect(bytes > minPlausibleContentBytes)
}

@MainActor @Test func renderAdvancedTab() async throws {
    let (_, model) = try makeStoreAndModel()
    await model.refreshMessageCount()
    let bytes = try renderSnapshot(
        SettingsAdvancedTab(model: model), size: settingsSize, to: "settings-advanced.png")
    #expect(bytes > minPlausibleContentBytes)
}

/// The alert path: `errorMessage` set on the shared model, rendered through
/// the real `SettingsView` root so its `.alert(...)` — the actual mechanism
/// every failure in `SettingsModel` reports through — is what's on screen,
/// not a stand-in for it. Compared against the same tab with no error set,
/// so a harness that silently fails to draw the alert (this offscreen
/// window is never key, and a system alert sheet may need that) shows up as
/// a byte-count match instead of a silent false pass.
@MainActor @Test func renderErrorStateDiffersFromNoError() async throws {
    let (store, model) = try makeStoreAndModel()
    try await seedServers(store: store, model: model)
    let cleanBytes = try renderSnapshot(
        SettingsView(model: model), size: settingsSize, to: "settings-no-error.png")

    model.errorMessage = "Couldn't remove the server: the operation couldn't be completed."
    let errorBytes = try renderSnapshot(
        SettingsView(model: model), size: settingsSize, to: "settings-error.png")

    #expect(cleanBytes > minPlausibleContentBytes)
    #expect(errorBytes > minPlausibleContentBytes)
    // The alert provably does NOT draw in this harness: the two renders come
    // out byte-identical. That is recorded as a *known* issue rather than a
    // hard failure, for two reasons. A permanently red test teaches everyone
    // to stop reading the suite, which costs more than this one gap. And
    // `withKnownIssue` fails if the issue ever stops occurring — so the day
    // the alert does start drawing, this test tells us instead of quietly
    // passing, and `settings-error.png` becomes trustworthy at exactly that
    // moment rather than whenever somebody happens to look.
    withKnownIssue("""
        The .alert(...) is presented from an offscreen NSWindow that is never \
        key, so it does not draw and settings-error.png shows the tab beneath \
        it. Do not trust that image as evidence the alert path renders.
        """) {
        #expect(errorBytes != cleanBytes)
    }
}

/// Servers is the densest tab (rows, toggles, steppers, inline fields), so
/// it is the one rendered in dark mode. Compared against the light render
/// for the same reason as the error-state pair above.
@MainActor @Test func renderServersTabDarkDiffersFromLight() async throws {
    let (store, model) = try makeStoreAndModel()
    try await seedServers(store: store, model: model)

    let lightBytes = try renderSnapshot(
        SettingsServersTab(model: model), size: settingsSize,
        colorScheme: .light, to: "settings-servers-populated-light-reference.png")
    let darkBytes = try renderSnapshot(
        SettingsServersTab(model: model), size: settingsSize,
        colorScheme: .dark, to: "settings-servers-populated-dark.png")

    #expect(lightBytes > minPlausibleContentBytes)
    #expect(darkBytes > minPlausibleContentBytes)
    #expect(lightBytes != darkBytes)
}

/// First-run onboarding (spec §6), at the size `AppDelegate` actually hosts
/// it in (`presentOnboardingIfNeeded`'s `NSWindow`). The literal first thing
/// a new user sees.
@MainActor @Test func renderOnboarding() async throws {
    let view = OnboardingView(
        onRequestAuthorization: { true },
        onFinish: {},
        onSkip: {})
    let bytes = try renderSnapshot(view, size: onboardingSize, to: "onboarding.png")
    #expect(bytes > minPlausibleContentBytes)
}
