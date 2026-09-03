import Foundation

/// How urgently macOS should interrupt for a notification.
///
/// There is deliberately no `.critical`: it needs an entitlement Apple grants
/// only by individual application (spec §6). Note also that `.timeSensitive`
/// needs an entitlement that cannot be signed with a local development
/// identity, so priorities 4 and 5 degrade to `.active` in development builds.
public enum NotificationInterruption: Sendable, Equatable {
    case passive
    case active
    case timeSensitive
}

/// Everything the app target needs to build a `UNNotificationRequest`.
///
/// This type is the seam that keeps `UserNotifications` out of `NtfyKit`: every
/// rule in spec §6 is decided here and tested as a pure function, and the app
/// target only translates.
public struct NotificationRequest: Sendable, Equatable {
    public let identifier: String
    public let threadIdentifier: String
    public let title: String
    public let body: String
    public let interruption: NotificationInterruption
    public let playsSound: Bool
    /// `nil` when the message has no actions — no category needs registering.
    public let categoryIdentifier: String?
    public let actions: [PresentableAction]
    /// Opened when the notification body is clicked, if set.
    public let clickURL: URL?
    /// Remote URL of an image attachment, if the message had one. Downloading
    /// it is the app target's job and is out of scope for this plan.
    public let attachmentURL: URL?

    public init(identifier: String, threadIdentifier: String, title: String, body: String,
                interruption: NotificationInterruption, playsSound: Bool,
                categoryIdentifier: String?, actions: [PresentableAction],
                clickURL: URL?, attachmentURL: URL?) {
        self.identifier = identifier
        self.threadIdentifier = threadIdentifier
        self.title = title
        self.body = body
        self.interruption = interruption
        self.playsSound = playsSound
        self.categoryIdentifier = categoryIdentifier
        self.actions = actions
        self.clickURL = clickURL
        self.attachmentURL = attachmentURL
    }
}
