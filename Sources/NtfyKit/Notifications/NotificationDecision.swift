import Foundation

/// Per-topic alert settings, read from the `Subscription` row.
public struct TopicAlertSettings: Sendable, Equatable {
    public let muted: Bool
    public let minAlertPriority: Int

    public init(muted: Bool, minAlertPriority: Int) {
        self.muted = muted
        self.minAlertPriority = minAlertPriority
    }
}

/// Whether an event should raise a notification, and exactly what it should
/// look like. A pure function of the event and the settings — no framework,
/// no I/O, no clock.
public enum NotificationDecision: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        case notAMessage
        case globallySilenced
        case topicMuted
        case belowTopicThreshold
    }

    case present(NotificationRequest)
    case suppress(Reason)

    /// ntfy allows at most three action buttons; more is a malformed message.
    private static let maxActions = 3

    public static func decide(event: NtfyEvent, serverID: UUID,
                              settings: TopicAlertSettings,
                              preferences: Preferences) -> NotificationDecision {
        guard event.kind == .message else { return .suppress(.notAMessage) }
        if preferences.recordOnlyNeverAlert { return .suppress(.globallySilenced) }
        if settings.muted { return .suppress(.topicMuted) }

        let priority = event.resolvedPriority
        guard priority.rawValue >= settings.minAlertPriority else {
            return .suppress(.belowTopicThreshold)
        }

        let actions = presentableActions(from: event.actions ?? [])

        return .present(NotificationRequest(
            identifier: "\(serverID.uuidString)/\(event.topic)/\(event.id)",
            threadIdentifier: "\(serverID.uuidString)/\(event.topic)",
            // A message with no title still needs one; the topic is the most
            // useful thing the user could see there.
            title: event.title ?? event.topic,
            body: event.message ?? "",
            interruption: interruption(for: priority),
            playsSound: priority.rawValue >= NtfyPriority.default.rawValue,
            categoryIdentifier: actions.isEmpty ? nil : categoryIdentifier(for: actions),
            actions: actions,
            clickURL: event.click.flatMap(URL.init(string:)),
            attachmentURL: event.attachment.flatMap { URL(string: $0.url) }))
    }

    private static func interruption(for priority: NtfyPriority) -> NotificationInterruption {
        switch priority {
        case .min, .low: .passive
        case .default: .active
        case .high, .max: .timeSensitive
        }
    }

    private static func presentableActions(from actions: [NtfyAction]) -> [PresentableAction] {
        actions.prefix(maxActions).compactMap { action in
            switch action.kind {
            case .view:
                guard let raw = action.url, let url = URL(string: raw) else { return nil }
                return PresentableAction(id: action.id, title: action.label, kind: .view(url: url))
            case .copy:
                guard let value = action.value else { return nil }
                return PresentableAction(id: action.id, title: action.label, kind: .copy(value: value))
            case .http:
                guard let raw = action.url, let url = URL(string: raw) else { return nil }
                return PresentableAction(
                    id: action.id, title: action.label,
                    kind: .http(url: url, method: action.method ?? "POST",
                                headers: action.headers ?? [:], body: action.body))
            case .broadcast, nil:
                // Android-only, or a kind this version does not know. Dropping
                // the button is better than showing an inert one.
                return nil
            }
        }
    }

    /// Stable for a given action shape, different for a different one. macOS
    /// caches categories by identifier, so a collision would show the wrong
    /// buttons on a later notification.
    ///
    /// This deliberately does *not* use `String.hashValue`: Swift seeds
    /// string hashing per process for DoS-resistance, so the same action
    /// shape hashes differently across launches. Within one launch that
    /// would be harmless (the app registers its categories fresh on every
    /// launch, and `hashValue` is consistent for the life of that process),
    /// but a notification the system already delivered — one still sitting
    /// in Notification Center when the app relaunches — carries the
    /// identifier the *previous* launch computed. If the next launch
    /// registers a different identifier for the same action shape, that
    /// older notification's category no longer resolves and it silently
    /// loses its buttons. FNV-1a over the UTF-8 bytes is deterministic
    /// across launches, so the same shape always maps to the same id.
    private static func categoryIdentifier(for actions: [PresentableAction]) -> String {
        let shape = actions.map { action -> String in
            switch action.kind {
            case .view: "view:\(action.id):\(action.title)"
            case .copy: "copy:\(action.id):\(action.title)"
            case .http: "http:\(action.id):\(action.title)"
            }
        }.joined(separator: "|")
        return "ntfy.actions.\(fnv1a(shape))"
    }

    /// FNV-1a, 64-bit. Simple, dependency-free, and deterministic — unlike
    /// `Hashable.hashValue`, it does not depend on a per-process random seed.
    private static func fnv1a(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}
