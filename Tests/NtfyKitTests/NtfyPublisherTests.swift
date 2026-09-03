import Foundation
import Testing
@testable import NtfyKit

/// Publishing, against a real local HTTP server (`MockNtfyServer`) rather
/// than a stubbed `URLProtocol`: this is the only code in the project that
/// writes to a server, and the thing most likely to be wrong about it is the
/// bytes on the wire — a method, a header, a JSON key — which a stub that
/// hands back a canned response would never exercise.

private func draft(topic: String = "alerts", title: String? = "Deploy failed",
                   body: String = "web-03 is down", priority: NtfyPriority = .high,
                   tags: [String] = ["warning"]) -> MessageDraft {
    MessageDraft(topic: topic, title: title, body: body,
                 priority: priority, tags: tags)
}

/// Decodes what actually arrived, rather than string-matching the body:
/// `JSONEncoder` does not promise key order, so an assertion on the raw text
/// would pin something Foundation never guaranteed and break on an OS update
/// for no reason.
private struct ReceivedPayload: Decodable, Equatable {
    var topic: String
    var title: String?
    var message: String
    var priority: Int?
    var tags: [String]?
}

private func received(from server: MockNtfyServer) async throws -> ReceivedPayload {
    let body = await server.lastRequestBody
    return try JSONDecoder().decode(ReceivedPayload.self, from: Data(body.utf8))
}

// MARK: - The request

@Test func publishSendsAPostWithTheDraftAsJSON() async throws {
    let server = MockNtfyServer()
    let base = try await server.start()
    defer { Task { await server.stop() } }
    await server.setResponse(status: 200, body: #"{"id":"m1","time":1,"event":"message","topic":"alerts"}"#)

    try await NtfyPublisher().publish(draft(), to: base, credential: .unauthenticated)

    let request = try #require(await server.receivedRequests.last)
    #expect(request.hasPrefix("POST "))
    #expect(request.contains("Content-Type: application/json"))
    #expect(try await received(from: server) == ReceivedPayload(
        topic: "alerts", title: "Deploy failed", message: "web-03 is down",
        priority: 4, tags: ["warning"]))
}

/// An empty title and an empty tag list are omitted from the body rather
/// than sent empty — see `NtfyEndpoint.publishRequest`. Both happen to work
/// either way against ntfy, which is exactly why nothing would catch this
/// drifting without a test.
@Test func aMinimalDraftOmitsTitleAndTagsEntirely() async throws {
    let server = MockNtfyServer()
    let base = try await server.start()
    defer { Task { await server.stop() } }
    await server.setResponse(status: 200, body: "{}")

    try await NtfyPublisher().publish(
        draft(title: nil, priority: .default, tags: []), to: base, credential: .unauthenticated)

    let payload = try await received(from: server)
    #expect(payload.title == nil)
    #expect(payload.tags == nil)
    #expect(payload.message == "web-03 is down")
}

/// A title of nothing but spaces is a title the user did not write.
@Test func aWhitespaceOnlyTitleIsOmittedToo() async throws {
    let server = MockNtfyServer()
    let base = try await server.start()
    defer { Task { await server.stop() } }
    await server.setResponse(status: 200, body: "{}")

    try await NtfyPublisher().publish(
        draft(title: "   "), to: base, credential: .unauthenticated)

    #expect(try await received(from: server).title == nil)
}

/// A non-ASCII title survives intact. The whole reason for choosing a JSON
/// body over `X-Title` (see `NtfyEndpoint.publishRequest`) — in the header
/// form this is the case that needs RFC 2047 encoding and silently arrives
/// as mojibake without it.
@Test func aNonASCIITitleSurvivesTheRoundTrip() async throws {
    let server = MockNtfyServer()
    let base = try await server.start()
    defer { Task { await server.stop() } }
    await server.setResponse(status: 200, body: "{}")

    try await NtfyPublisher().publish(
        draft(title: "Grüße – 温度 ⚠️"), to: base, credential: .unauthenticated)

    #expect(try await received(from: server).title == "Grüße – 温度 ⚠️")
}

@Test func publishSendsTheServersCredential() async throws {
    let server = MockNtfyServer()
    let base = try await server.start()
    defer { Task { await server.stop() } }
    await server.setResponse(status: 200, body: "{}")

    try await NtfyPublisher().publish(
        draft(), to: base, credential: .bearer(token: "tk_secret"))

    #expect(await server.receivedRequests.last?.contains("Authorization: Bearer tk_secret") == true)
}

/// And sends none when there is none — an unauthenticated server must not
/// get an empty `Authorization` header, which some servers reject outright.
@Test func publishSendsNoAuthorizationHeaderWhenUnauthenticated() async throws {
    let server = MockNtfyServer()
    let base = try await server.start()
    defer { Task { await server.stop() } }
    await server.setResponse(status: 200, body: "{}")

    try await NtfyPublisher().publish(draft(), to: base, credential: .unauthenticated)

    #expect(await server.receivedRequests.last?.lowercased().contains("authorization:") == false)
}

/// The same rule that guards streaming guards publishing, and it is checked
/// before anything is sent: a topic this client would refuse to subscribe to
/// cannot be published to either.
@Test func anInvalidTopicFailsBeforeAnyRequestIsMade() async throws {
    let server = MockNtfyServer()
    let base = try await server.start()
    defer { Task { await server.stop() } }

    await #expect(throws: NtfyEndpoint.Error.invalidTopic("has spaces")) {
        try await NtfyPublisher().publish(
            draft(topic: "has spaces"), to: base, credential: .unauthenticated)
    }
    #expect(await server.receivedRequests.isEmpty)
}

// MARK: - Status mapping

@Test(arguments: [
    (401, NtfyPublisher.Error.notAuthorized),
    (403, NtfyPublisher.Error.notAuthorized),
    (404, NtfyPublisher.Error.topicRejected),
    (413, NtfyPublisher.Error.tooLarge),
    (429, NtfyPublisher.Error.rateLimited),
    (500, NtfyPublisher.Error.unexpectedStatus(500)),
    (418, NtfyPublisher.Error.unexpectedStatus(418)),
])
func eachFailureStatusMapsToItsOwnError(status: Int, expected: NtfyPublisher.Error) async throws {
    let server = MockNtfyServer()
    let base = try await server.start()
    defer { Task { await server.stop() } }
    // A real ntfy error body, to pin that none of it reaches the error: the
    // message a user sees is this app's, and a server-controlled string has
    // no business in it (spec §9).
    await server.setResponse(status: status, body: #"{"code":40101,"error":"unauthorized"}"#)

    await #expect(throws: expected) {
        try await NtfyPublisher().publish(draft(), to: base, credential: .unauthenticated)
    }
}

/// 401 and 403 are deliberately one case: ntfy returns either depending on
/// configuration, and "check this server's credential" is the same next step
/// for both. Pinned so a later refactor that splits them has to do it
/// knowingly.
@Test func notAuthorizedCoversBoth401And403() {
    #expect(NtfyPublisher.Error.notAuthorized == NtfyPublisher.Error.notAuthorized)
    #expect(NtfyPublisher.Error.unexpectedStatus(401) != NtfyPublisher.Error.notAuthorized)
}

/// A 2xx other than 200 is still success. ntfy answers 200 today; treating
/// anything else in the range as a failure would be this client inventing a
/// stricter contract than HTTP has.
@Test func anyTwoHundredRangeStatusIsSuccess() async throws {
    let server = MockNtfyServer()
    let base = try await server.start()
    defer { Task { await server.stop() } }
    await server.setResponse(status: 202, body: "{}")

    try await NtfyPublisher().publish(draft(), to: base, credential: .unauthenticated)
}

/// Offline, DNS, TLS: propagates as the `URLError` it is rather than being
/// folded into `NtfyPublisher.Error`, so the caller can tell "the server
/// said no" from "there was no server to ask". Provoked with a port nothing
/// is listening on.
@Test func aTransportFailurePropagatesAsURLError() async throws {
    let deadURL = URL(string: "http://127.0.0.1:1")!

    await #expect(throws: URLError.self) {
        try await NtfyPublisher().publish(draft(), to: deadURL, credential: .unauthenticated)
    }
}
