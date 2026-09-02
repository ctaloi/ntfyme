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
/// - `MessageSnapshot`'s corrupt-actions site (`Log.store`, in
///   `Message.snapshot`) interpolates only a literal plus `serverID` — a
///   UUID this app generated locally, fixed-shape, never wire content. It
///   deliberately omits `messageID`: that value comes off the wire in the
///   server's `id` field, is not protocol like `event` is, and is not
///   length-bounded the way `event` is, so it does not qualify for the
///   carve-out above. If row-level correlation is ever actually needed,
///   the answer is a truncated digest of `uniqueKey` — fixed-shape,
///   non-reversible, and able to correlate one row across log lines
///   without leaking the topic it is derived from — never the key itself.
///   Not built now: one log site does not justify a hashing dependency.
/// - `MessageStore`'s missing-subscription site
///   (`advanceWatermarks(_:ids:serverID:)`) interpolates only `serverID`,
///   for the same reason as the corrupt-actions site above — never the
///   topic that has no matching `Subscription` row.
/// - `MessageStore.prune`'s attachment-deletion-failure site interpolates
///   only the failed `NSError`'s `domain` and `code` — a closed, fixed-shape
///   vocabulary, like `DegradedReason.logLabel` above. Never
///   `error.localizedDescription`: Cocoa's file-removal errors embed the
///   display name of the file they failed on, which is
///   `Attachment.localFilename` — content that ultimately traces back to a
///   server-provided attachment name, the same category `messageID` is
///   barred for above.
/// - `MessageStore.prune`'s non-component-filename site is a string literal
///   only — it deliberately does not interpolate `filename`, for the same
///   reason as the site above: that value is the same server-provided
///   attachment-name content, and here it is additionally the value that
///   just failed a path-component check, making it worth no more trust in a
///   log line than anywhere else.
/// - `Ingest.flush`'s two failure sites — the batch insert and the
///   `caughtUpTo` persist — interpolate only the failed `NSError`'s `domain`
///   and `code`, for the same reason as `prune`'s deletion-failure site. A
///   SwiftData or Cocoa error's description can embed a stored value, and
///   every stored value in this library is a message body, a topic, or a
///   `messageID`.
/// - `Ingest.Buffer`'s overflow site is a string literal only. It reports
///   that events were dropped, never which ones.
/// - `Backfill.run`'s success site interpolates only `result.inserted`, an
///   `Int` this process counted — the same fixed-shape, locally-generated
///   category as `serverID` above. It deliberately does not name the topic
///   being backfilled, which is precisely the value a caller would find most
///   useful and is barred for it.
/// - `Backfill.collectEvents`'s skipped-line site interpolates
///   `NtfyEventDecoder`'s `reason`, the same closed vocabulary (and the same
///   bounded `ignoredUnknownEvent` carve-out) as `ServerConnection`'s
///   skipped-line site. The two are worded differently on purpose, so a log
///   read can tell a one-shot poll's bad line from a subscription's.
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

    /// Persistence: inserts, watermark advances, retention.
    static let store = Logger(subsystem: subsystem, category: "store")
}
