import Foundation

/// An ntfy action this app can actually perform.
///
/// `broadcast` is deliberately absent: it is an Android intent and has no
/// meaning on macOS. Rendering it as a button that does nothing is worse than
/// omitting it, so it is dropped at decision time (spec §6).
/// `Codable` so an action can survive a round trip through a notification's
/// `userInfo`. When the user taps a button the app may have been relaunched
/// since the banner appeared, so the action cannot be looked up from memory —
/// it has to travel with the notification itself.
public struct PresentableAction: Sendable, Equatable, Identifiable, Codable {
    public enum Kind: Sendable, Equatable, Codable {
        case view(url: URL)
        case copy(value: String)
        case http(url: URL, method: String, headers: [String: String], body: String?)
    }

    public let id: String
    public let title: String
    public let kind: Kind

    public init(id: String, title: String, kind: Kind) {
        self.id = id
        self.title = title
        self.kind = kind
    }
}
