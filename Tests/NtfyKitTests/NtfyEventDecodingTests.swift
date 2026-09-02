import Foundation
import Testing
@testable import NtfyKit

private func decode(_ json: String) throws -> NtfyEvent {
    try JSONDecoder().decode(NtfyEvent.self, from: Data(json.utf8))
}

@Test func decodesRichMessage() throws {
    let e = try decode(Fixtures.richMessage)
    #expect(e.id == "XhKkViRHS9hx")
    #expect(e.kind == .message)
    #expect(e.topic == "alerts")
    #expect(e.title == "Service recovered")
    #expect(e.priority == 3)
    #expect(e.tags == ["white_check_mark"])
    #expect(e.contentType == "text/markdown")
    #expect(e.actions?.count == 1)
    #expect(e.actions?.first?.kind == .view)
    #expect(e.actions?.first?.label == "Open")
}

@Test func decodesMinimalMessage() throws {
    let e = try decode(Fixtures.minimalMessage)
    #expect(e.kind == .message)
    #expect(e.title == nil)
    #expect(e.priority == nil)
    #expect(e.tags == nil)
}

@Test func decodesOpenAndKeepalive() throws {
    #expect(try decode(Fixtures.openEvent).kind == .open)
    #expect(try decode(Fixtures.keepaliveEvent).kind == .keepalive)
}

/// Forward compatibility: an unknown event type must decode, not throw.
/// `kind` is nil so callers can ignore it without the stream dying.
@Test func decodesUnknownEventWithoutThrowing() throws {
    let e = try decode(Fixtures.unknownEvent)
    #expect(e.kind == nil)
    #expect(e.event == "some_future_event")
}

@Test func decodesAttachment() throws {
    let e = try decode(Fixtures.messageWithAttachment)
    #expect(e.attachment?.name == "graph.png")
    #expect(e.attachment?.size == 4096)
    #expect(e.attachment?.type == "image/png")
}

@Test func convertsTimeToDate() throws {
    let e = try decode(Fixtures.minimalMessage)
    #expect(e.date == Date(timeIntervalSince1970: 1_788_353_322))
}

@Test func mapsPriorityRawValues() {
    #expect(NtfyPriority(rawValue: 1) == .min)
    #expect(NtfyPriority(rawValue: 3) == .default)
    #expect(NtfyPriority(rawValue: 5) == .max)
    #expect(NtfyPriority(rawValue: 0) == nil)
    #expect(NtfyPriority(rawValue: 6) == nil)
}

/// An action kind ntfy adds after this build shipped must cost at most the
/// button. With `action` typed as a closed enum, the whole *message* failed to
/// decode and was dropped as malformed — body, title and all — for the sake of
/// one control the UI could simply have omitted. Same reasoning as
/// `NtfyEvent.event`, which was already a raw string for exactly this.
@Test func keepsAMessageWhoseActionKindIsUnknown() throws {
    let json = #"""
    {"id":"fut1","time":1788353400,"event":"message","topic":"alerts","message":"A1","actions":[{"id":"a1","action":"some_future_action","label":"Do it"},{"id":"a2","action":"view","label":"Open","url":"https://example.com/x"}]}
    """#
    let e = try decode(json)
    #expect(e.kind == .message)
    #expect(e.message == "A1")
    #expect(e.actions?.count == 2)
    // The unknown one survives with its raw value and reports no `kind`, so a
    // caller renders what it understands and skips the rest.
    #expect(e.actions?.first?.action == "some_future_action")
    #expect(e.actions?.first?.kind == nil)
    #expect(e.actions?.last?.kind == .view)
}
