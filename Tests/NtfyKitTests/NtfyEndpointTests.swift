import Foundation
import Testing
@testable import NtfyKit

private let base = URL(string: "https://ntfy.example.com")!

@Test func buildsAMultiTopicStreamURL() throws {
    let ep = NtfyEndpoint(baseURL: base, credential: .unauthenticated)
    let req = try ep.streamRequest(topics: ["a", "b", "c"], since: nil)
    #expect(req.url?.absoluteString == "https://ntfy.example.com/a,b,c/json")
}

@Test func appendsSinceWhenPresent() throws {
    let ep = NtfyEndpoint(baseURL: base, credential: .unauthenticated)
    let req = try ep.streamRequest(topics: ["a"], since: .unixTime(1788353322))
    #expect(req.url?.absoluteString == "https://ntfy.example.com/a/json?since=1788353322")
}

@Test func buildsAOneShotPollURL() throws {
    let ep = NtfyEndpoint(baseURL: base, credential: .unauthenticated)
    let req = try ep.pollRequest(topic: "a", since: .all)
    #expect(req.url?.absoluteString == "https://ntfy.example.com/a/json?poll=1&since=all")
}

@Test func attachesTheAuthorizationHeader() throws {
    let ep = NtfyEndpoint(baseURL: base, credential: .bearer(token: "tk_abc"))
    let req = try ep.streamRequest(topics: ["a"], since: nil)
    #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer tk_abc")
}

@Test func omitsAuthorizationWhenThereIsNoCredential() throws {
    let ep = NtfyEndpoint(baseURL: base, credential: .unauthenticated)
    let req = try ep.streamRequest(topics: ["a"], since: nil)
    #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
}

@Test func rejectsAnEmptyTopicList() {
    let ep = NtfyEndpoint(baseURL: base, credential: .unauthenticated)
    #expect(throws: NtfyEndpoint.Error.noTopics) {
        _ = try ep.streamRequest(topics: [], since: nil)
    }
}

/// A topic containing a comma or slash would silently change which topics are
/// subscribed, so it is rejected rather than escaped.
@Test func rejectsTopicsContainingSeparators() {
    let ep = NtfyEndpoint(baseURL: base, credential: .unauthenticated)
    #expect(throws: NtfyEndpoint.Error.invalidTopic("a,b")) {
        _ = try ep.streamRequest(topics: ["a,b"], since: nil)
    }
    #expect(throws: NtfyEndpoint.Error.invalidTopic("a/b")) {
        _ = try ep.streamRequest(topics: ["a/b"], since: nil)
    }
}

/// Validated against ntfy's own rule, `[-_A-Za-z0-9]{1,64}`, rather than
/// against the shorter list of characters that happen to break this client's
/// URL building. `#` was the concrete hole: it survived the old check and
/// truncated the request path at a URL fragment.
@Test func rejectsTopicsOutsideNtfysOwnCharacterSet() {
    let ep = NtfyEndpoint(baseURL: base, credential: .unauthenticated)
    for topic in ["a#b", "a b", "a\tb", "héllo", "a.b", "a:b", "a%b", ""] {
        #expect(throws: NtfyEndpoint.Error.invalidTopic(topic)) {
            _ = try ep.streamRequest(topics: [topic], since: nil)
        }
    }
}

@Test func acceptsTheLongestLegalTopicAndRejectsOneCharacterMore() throws {
    let ep = NtfyEndpoint(baseURL: base, credential: .unauthenticated)
    let longest = String(repeating: "a", count: 64)
    _ = try ep.streamRequest(topics: [longest], since: nil)

    let tooLong = String(repeating: "a", count: 65)
    #expect(throws: NtfyEndpoint.Error.invalidTopic(tooLong)) {
        _ = try ep.streamRequest(topics: [tooLong], since: nil)
    }
}

@Test func acceptsEveryCharacterClassNtfyAllows() throws {
    let ep = NtfyEndpoint(baseURL: base, credential: .unauthenticated)
    let req = try ep.streamRequest(topics: ["Ops-alerts_9"], since: nil)
    #expect(req.url?.absoluteString == "https://ntfy.example.com/Ops-alerts_9/json")
}

@Test func preservesABaseURLSubpath() throws {
    let ep = NtfyEndpoint(baseURL: URL(string: "https://example.com/ntfy")!, credential: .unauthenticated)
    let req = try ep.streamRequest(topics: ["a"], since: nil)
    #expect(req.url?.absoluteString == "https://example.com/ntfy/a/json")
}
