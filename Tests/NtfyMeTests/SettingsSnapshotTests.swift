import Testing
import SwiftUI
import AppKit
import SwiftData
import Foundation
@testable import NtfyMe
import NtfyKit

/// Headless PNG renders of the Settings tabs and the onboarding pane, for
/// visual review only — there is no snapshot-diff harness in this project
/// (see this wave's report).
///
/// Renders through an offscreen (never ordered onscreen) `NSWindow` +
/// `NSHostingView.cacheDisplay(in:to:)`, not `ImageRenderer`.
/// `ImageRenderer` renders `Form(.formStyle(.grouped))` blank and `List`
/// content as a corrupted placeholder glyph in this sandbox — reproduced
/// with the plain `ImageRenderer` probe every render-owning agent this wave
/// started from, and confirmed not specific to this file's views by seeing
/// the same corruption in the menu bar popover's own `List`. The
/// `NSWindow`-hosted approach renders both correctly; see this wave's report
/// for the full comparison. One caveat this technique does not overcome:
/// `DisclosureGroup`'s initial `isExpanded` state does not visually take
/// effect in a single synchronous capture (tried an extra layout/display
/// pass and disabling its implicit animation; neither changed the result),
/// so the Servers tab always renders with its rows collapsed here even
/// though the real, interactive app defaults them open.
///
/// Every fixture below uses placeholder content only — this repository is
/// public: "ntfy.sh" (the real public service, safe to name), "Home Lab" and
/// "Work Notices" as invented server names, `example.net`/`example.org`
/// (IANA-reserved documentation domains, RFC 2606) as their addresses, and
/// generic topic names. No credential value is ever set to anything other
/// than a placeholder string, and no rendered view shows a credential's
/// value at all — the Servers tab only ever displays a credential's *kind*.

private enum RenderError: Error {
    case failed(String)
}

/// Hosts `view` in an offscreen `NSWindow` (never `makeKeyAndOrderFront`) and
/// rasterizes it via `cacheDisplay(in:to:)` to `/tmp/ntfyshots/<filename>`.
@MainActor
private func renderPNG(_ view: some View, filename: String, size: CGSize, dark: Bool = false) throws {
    try FileManager.default.createDirectory(
        atPath: "/tmp/ntfyshots", withIntermediateDirectories: true)

    let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
    hosting.frame = NSRect(origin: .zero, size: size)

    let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled],
                          backing: .buffered, defer: false)
    window.contentView = hosting
    if dark {
        // The SwiftUI `.environment(\.colorScheme, .dark)` override alone
        // left native-chrome content (the bordered "Add Server" button, the
        // Divider above it) undrawn in this capture technique — setting the
        // window's actual `NSAppearance` is what a real dark-mode window
        // does, and fixes it.
        window.appearance = NSAppearance(named: .darkAqua)
    }
    window.layoutIfNeeded()
    hosting.layoutSubtreeIfNeeded()

    guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
        throw RenderError.failed("no bitmap rep for \(filename)")
    }
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw RenderError.failed("no PNG representation for \(filename)")
    }
    try png.write(to: URL(filePath: "/tmp/ntfyshots/\(filename)"))
}

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

private let settingsSize = CGSize(width: 520, height: 440)
private let onboardingSize = CGSize(width: 420, height: 340)

@MainActor @Test func renderGeneralTab() async throws {
    let (_, model) = try makeStoreAndModel()
    model.refreshPreferences()
    try renderPNG(SettingsGeneralTab(model: model), filename: "settings-general.png", size: settingsSize)
}

@MainActor @Test func renderServersTabPopulated() async throws {
    let (store, model) = try makeStoreAndModel()
    try await seedServers(store: store, model: model)
    try renderPNG(SettingsServersTab(model: model), filename: "settings-servers-populated.png", size: settingsSize)
}

@MainActor @Test func renderServersTabEmpty() async throws {
    let (_, model) = try makeStoreAndModel()
    await model.loadServers()
    try renderPNG(SettingsServersTab(model: model), filename: "settings-servers-empty.png", size: settingsSize)
}

@MainActor @Test func renderNotificationsTab() async throws {
    let (_, model) = try makeStoreAndModel()
    model.refreshPreferences()
    try renderPNG(SettingsNotificationsTab(model: model), filename: "settings-notifications.png", size: settingsSize)
}

@MainActor @Test func renderAdvancedTab() async throws {
    let (_, model) = try makeStoreAndModel()
    await model.refreshMessageCount()
    try renderPNG(SettingsAdvancedTab(model: model), filename: "settings-advanced.png", size: settingsSize)
}

/// The alert path: `errorMessage` set on the shared model, rendered through
/// the real `SettingsView` root so its `.alert(...)` — the actual mechanism
/// every failure in `SettingsModel` reports through — is what's on screen,
/// not a stand-in for it.
@MainActor @Test func renderErrorState() async throws {
    let (store, model) = try makeStoreAndModel()
    try await seedServers(store: store, model: model)
    model.errorMessage = "Couldn't remove the server: the operation couldn't be completed."
    try renderPNG(SettingsView(model: model), filename: "settings-error.png", size: settingsSize)
}

/// Servers is the densest tab (rows, toggles, steppers, inline fields), so
/// it is the one rendered in dark mode.
@MainActor @Test func renderServersTabDark() async throws {
    let (store, model) = try makeStoreAndModel()
    try await seedServers(store: store, model: model)
    let view = SettingsServersTab(model: model)
        .environment(\.colorScheme, .dark)
        .background(Color(nsColor: .windowBackgroundColor))
    try renderPNG(view, filename: "settings-servers-populated-dark.png", size: settingsSize, dark: true)
}

/// First-run onboarding (spec §6), at the size `AppDelegate` actually hosts
/// it in (`presentOnboardingIfNeeded`'s `NSWindow`).
@MainActor @Test func renderOnboarding() async throws {
    let view = OnboardingView(
        onRequestAuthorization: { true },
        onFinish: {},
        onSkip: {})
    try renderPNG(view, filename: "onboarding.png", size: onboardingSize)
}
