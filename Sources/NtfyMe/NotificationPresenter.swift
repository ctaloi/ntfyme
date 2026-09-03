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

    /// The system's current answer, for the Notifications tab's "is this
    /// actually working" question — distinct from `requestAuthorization`,
    /// which asks; this only reads. Can change any time System Settings is
    /// open, so callers should re-read it rather than cache it across a
    /// window staying open.
    ///
    /// Returns `SettingsNotificationAuthorization`, not `UNAuthorizationStatus`
    /// directly — the mapping happens here, the one place this app already
    /// imports `UserNotifications`, so `SettingsNotificationsTab.swift` never
    /// has to. `.provisional`/`.ephemeral` collapse into `.authorized`:
    /// notifications still show either way, and this app never requests
    /// either mode itself, so a user could only be in one of those states by
    /// some other app or a future change granting it, and this app's UI
    /// should read that the same as full authorization.
    func authorizationStatus() async -> SettingsNotificationAuthorization {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: .authorized
        case .denied: .denied
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
    }

    /// Shows the banner even when NtfyMe is the active app.
    ///
    /// Without this delegate method, macOS silently swallows a notification
    /// that is delivered while the app is frontmost — nothing is shown and
    /// nothing is logged. That is rare for an app with no visible window,
    /// but it is exactly the state the app is in whenever a window of its own
    /// is focused, which would make a real notification look like a broken
    /// one. `.list` keeps it in Notification Center afterwards; `.sound` only
    /// does anything if `present(_:)` set one, which is the priority rule from
    /// `NotificationDecision`, not a second decision made here.
    /// `nonisolated`, with the completion-handler form rather than the `async`
    /// one: the protocol requirement is not main-actor isolated, and neither
    /// `UNUserNotificationCenter` nor `UNNotification` is `Sendable`, so a
    /// `@MainActor` implementation cannot legally receive them under Swift 6.
    /// Nothing here touches either argument or any state of this class, so
    /// answering off the actor is safe as well as necessary.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
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
        // Everything an activation needs travels with the notification. A
        // banner can be tapped long after this launch has ended, so nothing
        // here may depend on in-memory state.
        var userInfo: [String: Any] = [Self.messageKeyKey: request.identifier]
        if let clickURL = request.clickURL { userInfo[Self.clickURLKey] = clickURL.absoluteString }
        if !request.actions.isEmpty,
           let encoded = try? JSONEncoder().encode(request.actions) {
            userInfo[Self.actionsKey] = encoded
        }
        content.userInfo = userInfo

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

    // MARK: - Activation

    nonisolated static let clickURLKey = "clickURL"
    nonisolated static let actionsKey = "actions"
    nonisolated static let messageKeyKey = "messageKey"

    /// What the user did to a delivered notification. Resolved here from the
    /// notification's own payload; acted on by `AppDelegate`, which owns the
    /// windows and the URL opening.
    nonisolated enum Activation: Sendable, Equatable {
        /// The body was clicked and the message carried a `click` URL.
        case openURL(URL)
        /// The body was clicked and it did not — spec §6 opens History at
        /// that message instead.
        case openHistory(messageKey: String)
        /// One of the message's own action buttons.
        case perform(PresentableAction)
    }

    /// Set by `AppDelegate`. Left as a no-op default so a presenter built in
    /// a test does nothing rather than reaching for windows that do not exist.
    var onActivation: (Activation) -> Void = { _ in }

    /// Resolves a tap into an `Activation`. Pure and `static` so the routing
    /// rules are testable without a notification centre — the delegate method
    /// below is then only plumbing.
    ///
    /// Returns `nil` for a dismissal, and for an action identifier that is not
    /// in the payload: a category identifier is a hash of the action set, so a
    /// notification from a previous launch whose actions have since changed
    /// can deliver an identifier this payload does not contain. Doing nothing
    /// is correct there — the alternative is performing the wrong action.
    nonisolated static func activation(
        forActionIdentifier identifier: String, userInfo: [AnyHashable: Any]
    ) -> Activation? {
        if identifier == UNNotificationDismissActionIdentifier { return nil }

        if identifier == UNNotificationDefaultActionIdentifier {
            if let raw = userInfo[clickURLKey] as? String,
               let url = NtfyURLPolicy.sanitized(raw) {
                return .openURL(url)
            }
            if let key = userInfo[messageKeyKey] as? String {
                return .openHistory(messageKey: key)
            }
            return nil
        }

        guard let data = userInfo[actionsKey] as? Data,
              let actions = try? JSONDecoder().decode([PresentableAction].self, from: data),
              let action = actions.first(where: { $0.id == identifier })
        else { return nil }
        return .perform(action)
    }

    /// `nonisolated` for the same reason as `willPresent`: the protocol
    /// requirement is not main-actor isolated and neither argument is
    /// `Sendable`, so the payload is resolved off the actor and only the
    /// resulting value — which is `Sendable` — crosses back.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let resolved = Self.activation(
            forActionIdentifier: response.actionIdentifier,
            userInfo: response.notification.request.content.userInfo)
        // The completion handler is called synchronously, on the thread the
        // delegate was invoked on, rather than captured into the `Task`: it is
        // not `Sendable`, and it only tells the system this delegate is done
        // deciding — which it is, since `activation` resolved above. The
        // window work then proceeds on the main actor without holding it up.
        if let resolved {
            Task { @MainActor in self.onActivation(resolved) }
        }
        completionHandler()
    }

}
