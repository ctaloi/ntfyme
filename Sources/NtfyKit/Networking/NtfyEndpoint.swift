import Foundation

/// Builds requests against one ntfy server.
public struct NtfyEndpoint: Sendable {
    public enum Error: Swift.Error, Equatable {
        case noTopics
        case invalidTopic(String)
        /// The configured server URL could not be turned into a request URL.
        /// Carries nothing deliberately: the base URL names the server host,
        /// which spec §9 treats as sensitive.
        case invalidServerURL
    }

    private let baseURL: URL
    private let credential: AuthCredential

    public init(baseURL: URL, credential: AuthCredential) {
        self.baseURL = baseURL
        self.credential = credential
    }

    /// Long-lived multi-topic stream. ntfy joins topics with commas and tags
    /// each returned message with its own `topic`, so one socket serves many
    /// subscriptions.
    public func streamRequest(topics: [String], since: SinceParameter?) throws -> URLRequest {
        guard !topics.isEmpty else { throw Error.noTopics }
        try topics.forEach(validate)

        var items: [URLQueryItem] = []
        if let since { items.append(URLQueryItem(name: "since", value: since.queryValue)) }
        return try request(path: topics.joined(separator: ","), query: items)
    }

    /// One-shot fetch used to backfill a newly added topic.
    public func pollRequest(topic: String, since: SinceParameter) throws -> URLRequest {
        try validate(topic)
        return try request(path: topic, query: [
            URLQueryItem(name: "poll", value: "1"),
            URLQueryItem(name: "since", value: since.queryValue),
        ])
    }

    /// ntfy's own topic rule, `[-_A-Za-z0-9]{1,64}`.
    private static let allowedTopicCharacters = Set(
        "-_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    )

    /// Validates against ntfy's rule rather than against a list of characters
    /// that would break *this* client's URL building. The narrower rule let
    /// through `#` (silently truncating the path at a fragment), whitespace,
    /// and non-ASCII — none of which name a real topic, so a request built
    /// from one can only fail confusingly at the server.
    private func validate(_ topic: String) throws {
        guard (1...64).contains(topic.count),
              topic.allSatisfy(Self.allowedTopicCharacters.contains)
        else { throw Error.invalidTopic(topic) }
    }

    /// Both steps below are documented as failable and were force-unwrapped
    /// with no stated justification. `baseURL` comes from user-entered server
    /// configuration, so "a valid `URL` always yields `URLComponents`" is not a
    /// claim this type is in a position to make — and crashing a menu bar app
    /// over a mistyped server address is the wrong outcome regardless. Both
    /// callers already throw.
    private func request(path: String, query: [URLQueryItem]) throws -> URLRequest {
        let url = baseURL.appending(path: path).appending(path: "json")
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw Error.invalidServerURL
        }
        if !query.isEmpty { components.queryItems = query }
        guard let requestURL = components.url else { throw Error.invalidServerURL }

        var req = URLRequest(url: requestURL)
        req.httpMethod = "GET"
        if let header = credential.authorizationHeader {
            req.setValue(header, forHTTPHeaderField: "Authorization")
        }
        return req
    }
}
