import Foundation
import Testing
@testable import NtfyKit

private let base = URL(string: "https://ntfy.example.com")!

@Test func buildsAMultiTopicStreamURL() throws {
    let ep = NtfyEndpoint(baseURL: base, credential: .none)
    let req = try ep.streamRequest(topics: ["a", "b", "c"], since: nil)
    #expect(req.url?.absoluteString == "https://ntfy.example.com/a,b,c/json")
}

@Test func appendsSinceWhenPresent() throws {
    let ep = NtfyEndpoint(baseURL: base, credential: .none)
    let req = try ep.streamRequest(topics: ["a"], since: .unixTime(1788353322))
    #expect(req.url?.absoluteString == "https://ntfy.example.com/a/json?since=1788353322")
}

@Test func buildsAOneShotPollURL() throws {
    let ep = NtfyEndpoint(baseURL: base, credential: .none)
    let req = try ep.pollRequest(topic: "a", since: .all)
    #expect(req.url?.absoluteString == "https://ntfy.example.com/a/json?poll=1&since=all")
}

@Test func attachesTheAuthorizationHeader() throws {
    let ep = NtfyEndpoint(baseURL: base, credential: .bearer(token: "tk_abc"))
    let req = try ep.streamRequest(topics: ["a"], since: nil)
    #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer tk_abc")
}

@Test func omitsAuthorizationWhenThereIsNoCredential() throws {
    let ep = NtfyEndpoint(baseURL: base, credential: .none)
    let req = try ep.streamRequest(topics: ["a"], since: nil)
    #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
}

@Test func rejectsAnEmptyTopicList() {
    let ep = NtfyEndpoint(baseURL: base, credential: .none)
    #expect(throws: NtfyEndpoint.Error.noTopics) {
        _ = try ep.streamRequest(topics: [], since: nil)
    }
}

/// A topic containing a comma or slash would silently change which topics are
/// subscribed, so it is rejected rather than escaped.
@Test func rejectsTopicsContainingSeparators() {
    let ep = NtfyEndpoint(baseURL: base, credential: .none)
    #expect(throws: NtfyEndpoint.Error.invalidTopic("a,b")) {
        _ = try ep.streamRequest(topics: ["a,b"], since: nil)
    }
    #expect(throws: NtfyEndpoint.Error.invalidTopic("a/b")) {
        _ = try ep.streamRequest(topics: ["a/b"], since: nil)
    }
}

@Test func preservesABaseURLSubpath() throws {
    let ep = NtfyEndpoint(baseURL: URL(string: "https://example.com/ntfy")!, credential: .none)
    let req = try ep.streamRequest(topics: ["a"], since: nil)
    #expect(req.url?.absoluteString == "https://example.com/ntfy/a/json")
}
