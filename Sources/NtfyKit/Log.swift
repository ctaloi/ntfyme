import os

/// The library's loggers.
///
/// `NtfyKit` imports no UI framework, but `os` is not a UI framework — it is
/// the platform's logging facility, and having one is what makes spec §10's
/// "no silent failures" achievable for conditions that have no UI to surface
/// them: a skipped ndjson line, a rejected `since` value, a history gap.
///
/// **Nothing logged here may contain a message body, a topic name, or a server
/// host** (spec §9). Every call site interpolates either a string literal or a
/// value drawn from a closed vocabulary — `DegradedReason.logLabel`,
/// `NtfyEventDecoder`'s fixed reasons — never an error's description and never
/// a line off the wire. `privacy: .public` is used deliberately at those sites
/// to keep the label readable in `log stream`; it is safe precisely because
/// the vocabulary is closed. Anything outside that vocabulary must not be
/// logged at all rather than logged privately, because a redacted value still
/// reaches the log store.
enum Log {
    private static let subsystem = "dev.aloi.NtfyMe"

    /// Connection lifecycle: state changes, reconnects, resume decisions.
    static let connection = Logger(subsystem: subsystem, category: "connection")

    /// Wire-level events: lines that could not be used.
    static let stream = Logger(subsystem: subsystem, category: "stream")
}
