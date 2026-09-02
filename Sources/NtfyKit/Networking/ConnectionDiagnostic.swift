import Foundation

/// One-shot facts about a connection that a level-triggered state enum cannot
/// carry, because the next state transition overwrites them.
///
/// `ConnectionState.degraded(.historyGap)` is replaced by `.open` as soon as
/// the first line arrives — typically within milliseconds — so a consumer
/// polling state can never observe it. Spec §10 requires the gap be surfaced,
/// so it is delivered here instead, where it is latched until read.
public enum ConnectionDiagnostic: Sendable, Equatable {
    /// The resume point predates the server's cache window, so the server is
    /// replaying its whole cache and some messages are unrecoverable.
    case historyGap(since: Date)
    /// The server rejected the `since` this client built; the next attempt
    /// falls back to `since=all`.
    case invalidSinceRejected
    /// A line could not be decoded. Never contains a message body.
    case skippedLine(reason: String)
    /// The credential was rejected; the connection will not retry.
    case unauthorized
}
