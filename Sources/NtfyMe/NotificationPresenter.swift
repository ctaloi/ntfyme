import Foundation
import UserNotifications
import NtfyKit

/// Translates a `NotificationRequest` into the system's notification API.
///
/// Deliberately contains no policy: every rule about whether and how to notify
/// lives in `NotificationDecision`, where it is unit tested. This file is the
/// untestable edge, so it stays as thin as possible.
///
/// `@MainActor`: this class holds mutable state (`registeredCategories`) and
/// is driven from `AppDelegate`, which is itself `@MainActor`. Pinning it
/// here is the narrowest way to satisfy Swift 6 strict concurrency without
/// inventing a second isolation domain for a class with no background work.
@MainActor
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()

    /// Every category registered so far this launch, keyed by identifier.
    /// `setNotificationCategories` *replaces* the system's set rather than
    /// merging into it, and a notification already sitting in Notification
    /// Center from a previous launch still carries that launch's category
    /// identifier — so this is seeded from the system's existing categories
    /// on first use (`currentCategories`) rather than starting empty, which
    /// would silently strip a still-visible notification's buttons the
    /// first time this launch registers any category at all.
    private var registeredCategories: [String: UNNotificationCategory]?

    /// Serializes every `registerCategory` call so no two ever race on the
    /// read-modify-write of `registeredCategories`. `@MainActor` alone does
    /// not close this: `currentCategories()` suspends at
    /// `await center.notificationCategories()`, and the actor is reentrant
    /// across that suspension. Two `present()` calls for *distinct*
    /// category IDs arriving in the same launch-time burst — before the
    /// first seed completes — would both see `registeredCategories == nil`,
    /// both build their own merged dictionary from the same stale snapshot,
    /// and the second caller's write would silently clobber the first's,
    /// dropping a category (and that message's buttons) from the next
    /// `setNotificationCategories` call, which replaces rather than merges.
    /// Chaining every call after the previous one's completion — the same
    /// fix this project already applied to `Ingest.flush`'s equivalent race
    /// — guarantees each call's merge is built on the previous call's
    /// finished result, never a snapshot racing against it.
    private var pendingRegistration: Task<Void, Never>?

    /// Requested after an explanatory pane, never as a cold prompt (spec §6).
    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            let ns = error as NSError
            Log.app.error("notification authorization failed: \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
            return false
        }
    }

    func present(_ request: NotificationRequest) async {
        if let categoryID = request.categoryIdentifier {
            await registerCategory(for: categoryID, actions: request.actions)
        }

        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.threadIdentifier = request.threadIdentifier
        content.interruptionLevel = level(for: request.interruption)
        if request.playsSound { content.sound = .default }
        if let categoryID = request.categoryIdentifier { content.categoryIdentifier = categoryID }
        if let clickURL = request.clickURL { content.userInfo = ["clickURL": clickURL.absoluteString] }

        do {
            try await center.add(UNNotificationRequest(
                identifier: request.identifier, content: content, trigger: nil))
        } catch {
            let ns = error as NSError
            Log.app.error("notification delivery failed: \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
        }
    }

    /// Registers a category, retaining every category registered so far —
    /// including ones seeded from a previous launch — since
    /// `setNotificationCategories` replaces rather than merges (see
    /// `registeredCategories`'s doc comment). Chained through
    /// `pendingRegistration` (see its doc comment) rather than performed
    /// directly, so concurrent calls never race on the merge.
    func registerCategory(for id: String, actions: [PresentableAction]) async {
        let previous = pendingRegistration
        let work = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.performRegistration(id: id, actions: actions)
        }
        pendingRegistration = work
        await work.value
    }

    private func performRegistration(id: String, actions: [PresentableAction]) async {
        var categories = await currentCategories()
        guard categories[id] == nil else { return }

        let unActions = actions.map {
            UNNotificationAction(identifier: $0.id, title: $0.title, options: [.foreground])
        }
        categories[id] = UNNotificationCategory(
            identifier: id, actions: unActions, intentIdentifiers: [], options: [])

        registeredCategories = categories
        center.setNotificationCategories(Set(categories.values))
    }

    /// The accumulated set, seeded once from the system on first access so a
    /// previous launch's still-visible categories are never dropped.
    private func currentCategories() async -> [String: UNNotificationCategory] {
        if let registeredCategories { return registeredCategories }
        let existing = await center.notificationCategories()
        let seeded = Dictionary(uniqueKeysWithValues: existing.map { ($0.identifier, $0) })
        registeredCategories = seeded
        return seeded
    }

    private func level(for interruption: NotificationInterruption) -> UNNotificationInterruptionLevel {
        switch interruption {
        case .passive: .passive
        case .active: .active
        // Requires an entitlement that cannot be signed locally, so this
        // degrades to .active in a development build (spec §11).
        case .timeSensitive: .timeSensitive
        }
    }
}
