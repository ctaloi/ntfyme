import Foundation

/// One action button attached to a message. ntfy allows at most three.
public struct NtfyAction: Codable, Sendable, Equatable, Identifiable {
    /// Action kinds ntfy defines. `broadcast` is Android-only; it decodes here
    /// so a message containing one is not lost, but the app does not present it.
    public enum Kind: String, Codable, Sendable {
        case view, http, broadcast, copy
    }

    public let id: String
    public let action: Kind
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
}
