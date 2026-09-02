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

    /// On public ntfy.sh, anyone who knows a topic name can publish to it
    /// (spec §9 — a topic name is effectively a password), so every URL,
    /// method, header and copy value below is attacker-controlled input, not
    /// a trusted server value, and is constrained accordingly.

    /// A URL macOS will actually open safely. `file://` reads local files;
    /// a custom scheme can launch another app. Restricting to the schemes a
    /// browser would treat as ordinary web content removes both.
    ///
    /// Internal, not `private`: `AttachmentDownloader` rejects attachment
    /// URLs against this same allow-list rather than keeping its own copy.
    static let allowedURLSchemes: Set<String> = ["http", "https"]

    /// The only methods an `http` action may use. Anything else — `TRACE`,
    /// a made-up verb — drops the action rather than being forwarded as-is.
    private static let allowedHTTPMethods: Set<String> = ["GET", "POST", "PUT", "DELETE"]

    /// Header names an action must not set: credentials that would leak to
    /// an attacker-chosen host (`Authorization`, `Cookie`), and hop-by-hop or
    /// framing headers `URLRequest` should own, not a message payload
    /// (`Host`, `Content-Length`, `Transfer-Encoding`, `Proxy-*`,
    /// `X-Forwarded-*`). Matched case-insensitively.
    private static let deniedHeaderNames: Set<String> = [
        "authorization", "cookie", "host", "content-length", "transfer-encoding",
    ]
    private static let deniedHeaderPrefixes = ["proxy-", "x-forwarded-"]

    /// A copy value long enough to be useful, short enough to not be abused
    /// as a way to dump arbitrary data onto the clipboard. Measured in UTF-8
    /// bytes, not `String.count`: a single base character plus many
    /// combining marks is one grapheme cluster, so a `count`-based cap does
    /// not bound the size of what actually lands on the clipboard at all.
    private static let maxCopyValueBytes = 1024

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
            clickURL: sanitizedURL(event.click),
            attachmentURL: event.attachment.flatMap { sanitizedURL($0.url) }))
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
                guard let url = sanitizedURL(action.url) else { return nil }
                return PresentableAction(id: action.id, title: action.label, kind: .view(url: url))
            case .copy:
                guard let value = action.value else { return nil }
                return PresentableAction(
                    id: action.id, title: action.label, kind: .copy(value: sanitizedCopyValue(value)))
            case .http:
                guard let url = sanitizedURL(action.url) else { return nil }
                let method = (action.method ?? "POST").uppercased()
                guard allowedHTTPMethods.contains(method) else { return nil }
                return PresentableAction(
                    id: action.id, title: action.label,
                    kind: .http(url: url, method: method,
                                headers: sanitizedHeaders(action.headers), body: action.body))
            case .broadcast, nil:
                // Android-only, or a kind this version does not know. Dropping
                // the button is better than showing an inert one.
                return nil
            }
        }
    }

    /// `nil` for a missing, unparseable, or unsafely-schemed URL — see
    /// `allowedURLSchemes`'s doc comment. Used for both action URLs (drops
    /// the action) and `clickURL` (nulls the click, keeps the notification).
    private static func sanitizedURL(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), allowedURLSchemes.contains(scheme)
        else { return nil }
        return url
    }

    /// Drops any header a message should not be able to set — see
    /// `deniedHeaderNames`'s doc comment. Everything else passes through
    /// unchanged: the header allow-list this app cares about is small and
    /// closed, unlike the set of headers a legitimate action might send.
    private static func sanitizedHeaders(_ headers: [String: String]?) -> [String: String] {
        guard let headers else { return [:] }
        return headers.filter { key, _ in
            let lower = key.lowercased()
            return !deniedHeaderNames.contains(lower)
                && !deniedHeaderPrefixes.contains { lower.hasPrefix($0) }
        }
    }

    /// Strips ASCII control characters — newline and carriage return above
    /// all, since a pasted one can execute as a shell command — and caps the
    /// length. Sanitizes rather than drops: a truncated, control-free copy
    /// value is still useful; a rejected action is not more useful than a
    /// safe one.
    private static func sanitizedCopyValue(_ value: String) -> String {
        let stripped = String(value.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F })
        return truncatedToUTF8Bytes(stripped, limit: maxCopyValueBytes)
    }

    /// Truncates to at most `limit` UTF-8 bytes without splitting a
    /// multi-byte scalar — building the result one whole scalar at a time,
    /// stopping before any scalar that would push the running byte count
    /// past `limit`, rather than slicing raw UTF-8 bytes.
    private static func truncatedToUTF8Bytes(_ string: String, limit: Int) -> String {
        var result = String.UnicodeScalarView()
        var byteCount = 0
        for scalar in string.unicodeScalars {
            let scalarBytes = String(scalar).utf8.count
            guard byteCount + scalarBytes <= limit else { break }
            result.append(scalar)
            byteCount += scalarBytes
        }
        return String(result)
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
