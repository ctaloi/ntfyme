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
    #expect(e.actions?.first?.action == .view)
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
