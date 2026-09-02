import Foundation

/// One action button attached to a message. ntfy allows at most three.
public struct NtfyAction: Codable, Sendable, Equatable, Identifiable {
    /// Action kinds ntfy defines today. `broadcast` is Android-only; it decodes
    /// here so a message containing one is not lost, but the app does not
    /// present it.
    public enum Kind: String, Sendable {
        case view, http, broadcast, copy
    }

    public let id: String
    /// Kept as the raw wire value for the same reason `NtfyEvent.event` is: a
    /// closed enum here means a message carrying an action kind ntfy adds later
    /// fails to decode *entirely* and is dropped as malformed — the whole
    /// message, not just the button it could not render. Callers switch on
    /// `kind` and skip `nil`.
    public let action: String
    public let label: String
    public let clear: Bool?

    // view / http
    public let url: String?
    // http
    public let method: String?
    public let headers: [String: String]?
    public let body: String?
    // copy
    public let value: String?
    // broadcast
    public let intent: String?
    public let extras: [String: String]?

    public var kind: Kind? { Kind(rawValue: action) }
}
