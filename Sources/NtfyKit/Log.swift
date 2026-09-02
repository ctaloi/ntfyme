import os

/// The library's loggers.
///
/// `NtfyKit` imports no UI framework, but `os` is not a UI framework — it is
/// the platform's logging facility, and having one is what makes spec §10's
/// "no silent failures" achievable for conditions the UI cannot carry on its
/// own: a skipped ndjson line has no state to sit in at all, and a rejected
/// `since` value and a history gap reach the state enum only as a transient
/// that the next line overwrites.
///
/// **Nothing logged here may contain a message body, a topic name, or a server
/// host** (spec §9). What actually guarantees that, site by site:
///
/// - Most interpolations are a string literal, or a value from a closed
///   vocabulary — `DegradedReason.logLabel`, `NtfyEventDecoder`'s fixed
///   reasons. Never an error's description: `URLError`'s carries the whole
///   subscribe URL, and `DecodingError`'s quotes the offending line.
/// - **One value does come off the wire**, and it is worth knowing about
///   rather than being surprised by: the reason for a skipped
///   `ignoredUnknownEvent` line embeds the server's `event` field. That field
///   is protocol, not payload — a publisher cannot write into it — so no
///   message body reaches a log through it, and `NtfyEventDecoder` bounds it
///   to `unknownEventTypeLimit` characters so an unbounded wire string cannot
///   either. A new log site interpolating anything else off the wire needs
///   its own argument, not this one.
///
/// `privacy: .public` is used deliberately, to keep these labels readable in
/// `log stream`. The alternative is not a safety net: `.private` hides a value
/// from an ordinary log read but is not a promise it was never recorded, so
/// anything genuinely sensitive must not be logged at all rather than logged
/// privately.
enum Log {
    private static let subsystem = "dev.aloi.NtfyMe"

    /// Connection lifecycle: state changes, reconnects, resume decisions.
    static let connection = Logger(subsystem: subsystem, category: "connection")

    /// Wire-level events: lines that could not be used.
    static let stream = Logger(subsystem: subsystem, category: "stream")
}
