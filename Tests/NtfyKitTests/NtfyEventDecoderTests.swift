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
    guard case .malformed(let line, _) = decoder.decode(line: #"{"id":"a","tim"#) else {
        Issue.record("expected .malformed"); return
    }
    #expect(line.hasPrefix("{"))
}

@Test func reportsValidJsonMissingRequiredFieldsAsMalformed() {
    guard case .malformed = decoder.decode(line: #"{"hello":"world"}"#) else {
        Issue.record("expected .malformed"); return
    }
}
