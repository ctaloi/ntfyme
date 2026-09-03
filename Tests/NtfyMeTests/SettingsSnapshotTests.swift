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
/// **Every content assertion below is `distinctColorCount`, not a byte
/// floor.** A blank Settings-sized PNG is 18,960 bytes — still a
/// full-resolution image, just of nothing — so a byte floor set below that
/// (as this file's first version was) cannot fail on a surface that drew
/// nothing at all, which is exactly the regression this suite exists to
/// catch. A blank render has 1-2 distinct colours regardless of size or
/// display scale; a real tab has dozens. (`distinctColorCount` composites
/// onto opaque white before counting — an earlier version did not, and read
/// `ContentUnavailableView`'s black-text-at-alpha as a single colour despite
/// rendering correctly; fixed upstream in `SnapshotSupport.swift`.) The
/// light/dark Servers pair is deliberately *not* compared against each
/// other — see `renderServersTabPopulatedLightAndDark`'s doc comment for
/// why a divergence check of any kind is the wrong tool there.
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
private func makeStoreAndModel(
    notificationAuthorization: SettingsNotificationAuthorization = .notDetermined
) throws -> (store: MessageStore, model: SettingsModel) {
    let container = try ModelContainer(
        for: Server.self, Subscription.self, Message.self, Attachment.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let store = MessageStore(modelContainer: container)
    let defaults = UserDefaults(suiteName: "dev.aloi.NtfyMe.snapshotTests.\(UUID().uuidString)")!
    let preferences = PreferencesStore(defaults: defaults)
    let keychain = KeychainStore(service: "dev.aloi.NtfyMe.snapshotTests.\(UUID().uuidString)")
    // Same isolated suite as `preferences` above — different key namespace,
    // no collision — so `seedDefaultServerIfNeeded`'s flag (and
    // `defaultMinAlertPriority`'s read) never touch the real
    // `UserDefaults.standard`, the same isolation every other fixture here
    // already gets.
    let model = SettingsModel(store: store, preferences: preferences, keychain: keychain,
                              defaults: defaults,
                              notificationAuthorizationStatus: { notificationAuthorization })
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

/// A blank render measures 1-2 distinct colours regardless of size or
/// display scale (`distinctColorCount`'s doc comment); every real tab in
/// this file measures in the dozens. 5 sits well clear of both.
private let minPlausibleColorCount = 5

/// Catches a root that forgot to paint its own ground — the exact bug
/// `ContentUnavailableView` had in `SettingsServersTab`'s empty state, and
/// the one `distinctColorCount` cannot see once it composites onto white.
/// Calibrated across this wave's four affected surfaces: every legitimate
/// render measures 0.889 or above, an unpainted one 0.053 — an order of
/// magnitude apart. 0.85 clears the lowest legitimate case
/// (`settings-servers-empty.png` at 0.889) with room, while still failing a
/// broken one hard. If a render's measured alpha ever drifts down toward
/// this line, that is a real regression to report, not a reason to lower it.
private let minPlausibleAlpha = 0.85

private func path(_ filename: String) -> String { "/tmp/ntfyshots/\(filename)" }

/// Covers the merged Advanced content too (export/clear, stored-message
/// count) — that tab no longer exists as its own type; its former render
/// test's job is now this one, since the content moved here.
@MainActor @Test(requiresSnapshotRendering) func renderGeneralTab() async throws {
    let (_, model) = try makeStoreAndModel()
    model.refreshPreferences()
    await model.refreshMessageCount()
    let filename = "settings-general.png"
    _ = try renderSnapshot(SettingsGeneralTab(model: model), size: settingsSize, to: filename)
    #expect(try distinctColorCount(ofPNGAt: path(filename)) > minPlausibleColorCount)
    #expect(try meanAlpha(ofPNGAt: path(filename)) > minPlausibleAlpha)
}

@MainActor @Test(requiresSnapshotRendering) func renderServersTabPopulatedAndEmptyDiffer() async throws {
    let (store, populatedModel) = try makeStoreAndModel()
    try await seedServers(store: store, model: populatedModel)
    let populatedFile = "settings-servers-populated.png"
    let populatedBytes = try renderSnapshot(
        SettingsServersTab(model: populatedModel), size: settingsSize, to: populatedFile)

    let (_, emptyModel) = try makeStoreAndModel()
    await emptyModel.loadServers()
    let emptyFile = "settings-servers-empty.png"
    let emptyBytes = try renderSnapshot(
        SettingsServersTab(model: emptyModel), size: settingsSize, to: emptyFile)

    #expect(try distinctColorCount(ofPNGAt: path(populatedFile)) > minPlausibleColorCount)
    #expect(try distinctColorCount(ofPNGAt: path(emptyFile)) > minPlausibleColorCount)
    #expect(try meanAlpha(ofPNGAt: path(populatedFile)) > minPlausibleAlpha)
    // The closest-to-the-line case (see `minPlausibleAlpha`'s doc comment):
    // this state's `ContentUnavailableView` painted no ground of its own
    // until `SettingsServersTab` gave it one explicitly.
    #expect(try meanAlpha(ofPNGAt: path(emptyFile)) > minPlausibleAlpha)

    // Three server rows vs. a `ContentUnavailableView` must not coincide.
    #expect(populatedBytes != emptyBytes)
}

/// Three renders, one per `SettingsNotificationAuthorization` case — the
/// tab's whole job is answering "why isn't this alerting", so its three
/// distinct states (`.onAppear`'s refresh is called manually here rather
/// than relied on, matching every other fixture in this file: it doesn't
/// reliably fire under this offscreen capture technique) are each worth a
/// look, not just the default.
@MainActor @Test(requiresSnapshotRendering) func renderNotificationsTabNotDetermined() async throws {
    let (_, model) = try makeStoreAndModel(notificationAuthorization: .notDetermined)
    model.refreshPreferences()
    await model.refreshNotificationAuthorization()
    let filename = "settings-notifications-not-determined.png"
    _ = try renderSnapshot(SettingsNotificationsTab(model: model), size: settingsSize, to: filename)
    #expect(try distinctColorCount(ofPNGAt: path(filename)) > minPlausibleColorCount)
    #expect(try meanAlpha(ofPNGAt: path(filename)) > minPlausibleAlpha)
}

@MainActor @Test(requiresSnapshotRendering) func renderNotificationsTabAuthorized() async throws {
    let (_, model) = try makeStoreAndModel(notificationAuthorization: .authorized)
    model.refreshPreferences()
    await model.refreshNotificationAuthorization()
    let filename = "settings-notifications-authorized.png"
    _ = try renderSnapshot(SettingsNotificationsTab(model: model), size: settingsSize, to: filename)
    #expect(try distinctColorCount(ofPNGAt: path(filename)) > minPlausibleColorCount)
    #expect(try meanAlpha(ofPNGAt: path(filename)) > minPlausibleAlpha)
}

@MainActor @Test(requiresSnapshotRendering) func renderNotificationsTabDenied() async throws {
    let (_, model) = try makeStoreAndModel(notificationAuthorization: .denied)
    model.refreshPreferences()
    await model.refreshNotificationAuthorization()
    let filename = "settings-notifications-denied.png"
    _ = try renderSnapshot(SettingsNotificationsTab(model: model), size: settingsSize, to: filename)
    #expect(try distinctColorCount(ofPNGAt: path(filename)) > minPlausibleColorCount)
    #expect(try meanAlpha(ofPNGAt: path(filename)) > minPlausibleAlpha)
}

/// The alert path: `errorMessage` set on the shared model, rendered through
/// the real `SettingsView` root so its `.alert(...)` — the actual mechanism
/// every failure in `SettingsModel` reports through — is what's on screen,
/// not a stand-in for it.
///
/// Two kinds of assertion here, deliberately not confused with each other.
/// The `distinctColorCount` floors are live: they fail if either render
/// stops showing real content, and they do not depend on the alert working.
/// The byte-identity check inside `withKnownIssue` is the one assertion
/// that is actually *about* the alert, and it is expected to keep firing —
/// the alert provably does not draw from a never-key offscreen window — so
/// it is quarantined rather than left as a permanent hard failure. Without
/// the colour-count floors, this test would have had no assertion capable
/// of failing on its own account once the known issue is set aside, which
/// is the same shape of gap `distinctColorCount` was written to close.
@MainActor @Test(requiresSnapshotRendering) func renderErrorStateDiffersFromNoError() async throws {
    let (store, model) = try makeStoreAndModel()
    try await seedServers(store: store, model: model)
    let cleanFile = "settings-no-error.png"
    let cleanBytes = try renderSnapshot(SettingsView(model: model), size: settingsSize, to: cleanFile)

    model.errorMessage = "Couldn't remove the server: the operation couldn't be completed."
    let errorFile = "settings-error.png"
    let errorBytes = try renderSnapshot(SettingsView(model: model), size: settingsSize, to: errorFile)

    #expect(try distinctColorCount(ofPNGAt: path(cleanFile)) > minPlausibleColorCount)
    #expect(try distinctColorCount(ofPNGAt: path(errorFile)) > minPlausibleColorCount)
    #expect(try meanAlpha(ofPNGAt: path(cleanFile)) > minPlausibleAlpha)
    #expect(try meanAlpha(ofPNGAt: path(errorFile)) > minPlausibleAlpha)

    withKnownIssue("""
        The .alert(...) is presented from an offscreen NSWindow that is never \
        key, so it does not draw and settings-error.png shows the tab beneath \
        it. Do not trust that image as evidence the alert path renders.
        """) {
        #expect(errorBytes != cleanBytes)
    }
}

/// Servers is the densest tab (rows, toggles, steppers, inline fields), so
/// it is the one rendered in dark mode.
///
/// Deliberately **not** a comparison between the light and dark renders —
/// no `!=`, no byte-size or luminance diff. Measured on this exact pair: a
/// broken render (dark mode without a recoloured background, unreadable
/// white-on-white) diverges from its light counterpart *more* than a
/// correct one does, so any divergence threshold has its ordering inverted
/// and nothing between "always trips" and "never trips" catches the
/// regression. `distinctColorCount` per render, independently, is what
/// actually distinguishes them: broken renders measure 1-2, correct ones
/// 25-29.
@MainActor @Test(requiresSnapshotRendering) func renderServersTabPopulatedLightAndDark() async throws {
    let (store, model) = try makeStoreAndModel()
    try await seedServers(store: store, model: model)

    let lightFile = "settings-servers-populated-light-reference.png"
    _ = try renderSnapshot(
        SettingsServersTab(model: model), size: settingsSize,
        colorScheme: .light, to: lightFile)
    let darkFile = "settings-servers-populated-dark.png"
    _ = try renderSnapshot(
        SettingsServersTab(model: model), size: settingsSize,
        colorScheme: .dark, to: darkFile)

    #expect(try distinctColorCount(ofPNGAt: path(lightFile)) > minPlausibleColorCount)
    #expect(try distinctColorCount(ofPNGAt: path(darkFile)) > minPlausibleColorCount)
    #expect(try meanAlpha(ofPNGAt: path(lightFile)) > minPlausibleAlpha)
    #expect(try meanAlpha(ofPNGAt: path(darkFile)) > minPlausibleAlpha)
}

/// First-run onboarding (spec §6), at the size `AppDelegate` actually hosts
/// it in (`presentOnboardingIfNeeded`'s `NSWindow`). The literal first thing
/// a new user sees.
@MainActor @Test(requiresSnapshotRendering) func renderOnboarding() async throws {
    let view = OnboardingView(
        onRequestAuthorization: { true },
        onFinish: {},
        onSkip: {})
    let filename = "onboarding.png"
    _ = try renderSnapshot(view, size: onboardingSize, to: filename)
    #expect(try distinctColorCount(ofPNGAt: path(filename)) > minPlausibleColorCount)
    #expect(try meanAlpha(ofPNGAt: path(filename)) > minPlausibleAlpha)
}
