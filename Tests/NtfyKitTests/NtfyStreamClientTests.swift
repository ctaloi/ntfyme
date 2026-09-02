import Foundation
import Testing
@testable import NtfyKit

private func endpoint(_ base: URL) -> NtfyEndpoint {
    NtfyEndpoint(baseURL: base, credential: .unauthenticated)
}

@Test func yieldsDecodedEventsFromTheStream() async throws {
    let server = MockNtfyServer()
    let base = try await server.start()
    defer { Task { await server.stop() } }

    await server.enqueue(line: Fixtures.openEvent)
    await server.enqueue(line: Fixtures.minimalMessage)

    let request = try endpoint(base).streamRequest(topics: ["alerts"], since: nil)
    var kinds: [NtfyEvent.Kind?] = []
    for try await element in NtfyStreamClient().stream(request) {
        if case .event(let e) = element { kinds.append(e.kind) }
    }
    #expect(kinds == [.open, .message])
}

/// A malformed line is reported and skipped; the events around it still arrive.
@Test func skipsMalformedLinesWithoutEndingTheStream() async throws {
    let server = MockNtfyServer()
    let base = try await server.start()
    defer { Task { await server.stop() } }

    await server.enqueue(line: Fixtures.openEvent)
    await server.enqueue(line: #"{"id":"broken"#)
    await server.enqueue(line: Fixtures.minimalMessage)

    let request = try endpoint(base).streamRequest(topics: ["alerts"], since: nil)
    var events = 0
    var skipped = 0
    for try await element in NtfyStreamClient().stream(request) {
        switch element {
        case .event: events += 1
        case .skippedLine: skipped += 1
        }
    }
    #expect(events == 2)
    #expect(skipped == 1)
}

/// `skippedLine`'s reason is logged verbatim by `ServerConnection`, so the
/// no-body invariant has to hold at this seam too, not only inside the decoder.
@Test func aSkippedLineNeverCarriesTheMessageBody() async throws {
    let server = MockNtfyServer()
    let base = try await server.start()
    defer { Task { await server.stop() } }

    let body = "db-01.internal.example is DOWN"
    await server.enqueue(line: #"{"id":"a","time":1,"event":"message","topic":"alerts","message":"\#(body)"#)

    let request = try endpoint(base).streamRequest(topics: ["alerts"], since: nil)
    var reasons: [String] = []
    for try await element in NtfyStreamClient().stream(request) {
        if case .skippedLine(let reason) = element { reasons.append(reason) }
    }
    #expect(reasons == ["malformed line: not valid JSON"])
}

@Test func mapsUnauthorizedToATypedError() async throws {
    let server = MockNtfyServer()
    let base = try await server.start()
    defer { Task { await server.stop() } }
    await server.setResponse(status: 401, body: #"{"code":40101,"error":"unauthorized"}"#)

    let request = try endpoint(base).streamRequest(topics: ["alerts"], since: nil)
    await #expect(throws: NtfyStreamClient.Error.unauthorized) {
        for try await _ in NtfyStreamClient().stream(request) {}
    }
}

/// HTTP 400 code 40008 means the client built a bad `since` value — a bug,
/// not a server condition, so it gets its own case (spec §10).
@Test func mapsInvalidSinceToATypedError() async throws {
    let server = MockNtfyServer()
    let base = try await server.start()
    defer { Task { await server.stop() } }
    await server.setResponse(status: 400, body: #"{"code":40008,"error":"invalid since parameter"}"#)

    let request = try endpoint(base).streamRequest(topics: ["alerts"], since: nil)
    await #expect(throws: NtfyStreamClient.Error.invalidSince) {
        for try await _ in NtfyStreamClient().stream(request) {}
    }
}
