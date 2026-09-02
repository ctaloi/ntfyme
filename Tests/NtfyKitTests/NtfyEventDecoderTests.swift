import Testing
@testable import NtfyKit

private let decoder = NtfyEventDecoder()

@Test func decodesAValidLineToAnEvent() {
    guard case .event(let e) = decoder.decode(line: Fixtures.minimalMessage) else {
        Issue.record("expected .event"); return
    }
    #expect(e.id == "J7rfOekQUOkP")
}

@Test func reportsUnknownEventTypesSeparately() {
    guard case .ignoredUnknownEvent(let name) = decoder.decode(line: Fixtures.unknownEvent) else {
        Issue.record("expected .ignoredUnknownEvent"); return
    }
    #expect(name == "some_future_event")
}

@Test func treatsBlankLinesAsEmpty() {
    #expect(decoder.decode(line: "") == .empty)
    #expect(decoder.decode(line: "   \t ") == .empty)
}

/// A truncated or corrupt line must be reported, never thrown — the stream
/// stays alive and the caller logs the skip.
@Test func reportsMalformedLinesWithoutThrowing() {
    guard case .malformed(let reason) = decoder.decode(line: #"{"id":"a","tim"#) else {
        Issue.record("expected .malformed"); return
    }
    #expect(reason == "not valid JSON")
}

@Test func reportsValidJsonMissingRequiredFieldsAsMalformed() {
    guard case .malformed(let reason) = decoder.decode(line: #"{"hello":"world"}"#) else {
        Issue.record("expected .malformed"); return
    }
    // The key name is schema, not content, so naming it is safe and useful.
    #expect(reason == "missing key: id")
}

/// The invariant the whole `Outcome.malformed` shape exists to protect: a
/// message body is sensitive (spec §9) and must never reach a reason string,
/// which is destined for a log.
///
/// This is not hypothetical. `String(describing:)` on a `DecodingError` — the
/// obvious implementation — embeds the underlying `NSError`, which quotes the
/// offending character straight out of the line ("Unexpected character 'o' …
/// around line 1, column 2."), and the previous shape additionally carried the
/// entire line as an associated value on a public type.
@Test func aMalformedLineNeverLeaksItsContentIntoTheReason() {
    let body = "db-01.internal.example is DOWN"
    let cases = [
        // Truncated mid-body.
        #"{"id":"a","time":1,"event":"message","topic":"alerts","message":"\#(body)"#,
        // Not JSON at all.
        "\(body)",
        // Well-formed JSON, wrong shape.
        #"{"message":"\#(body)"}"#,
        // Right shape, wrong type on a required field.
        #"{"id":"a","time":"\#(body)","event":"message","topic":"alerts"}"#,
    ]
    for line in cases {
        guard case .malformed(let reason) = decoder.decode(line: line) else {
            Issue.record("expected .malformed for \(line.prefix(12))"); continue
        }
        #expect(reason.contains(body) == false)
        #expect(reason.contains("db-01") == false)
    }
}
