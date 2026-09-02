import Foundation

/// Observable state of one server's connection. Drives the menu bar icon.
public enum ConnectionState: Sendable, Equatable {
    case idle
    case connecting
    case open
    case degraded(reason: String)
    case backoff(attempt: Int)
    /// Terminal until credentials change: retrying a rejected credential only
    /// burns rate limit.
    case unauthorized
}
