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

    /// Publishes one message: `POST` to the server's base URL with a JSON
    /// body.
    ///
    /// Its own builder rather than a `method:` parameter on the private
    /// `request(path:query:)` below. That one appends `/json` to the path,
    /// which a publish must not have, and threading two behaviours through
    /// one function to save a few lines is how that function stops being
    /// readable. What it *does* share is what matters: the same topic
    /// validation and the same credential application, so a topic this
    /// client refuses to stream cannot be published to either, and a
    /// publish authenticates exactly as a subscribe does.
    ///
    /// JSON body rather than `POST /{topic}` with `X-Title`/`X-Priority`
    /// headers. ntfy supports both; the header form needs a non-ASCII title
    /// percent- or RFC 2047-encoded to survive an HTTP header, which is how
    /// a mojibake bug arrives weeks later in the one field nobody tested
    /// with an umlaut. The body is also the shape `NtfyEvent` already
    /// decodes, so the two directions stay symmetric.
    public func publishRequest(_ draft: MessageDraft) throws -> URLRequest {
        try validate(draft.topic)
        guard let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let requestURL = components.url else {
            throw Error.invalidServerURL
        }

        var req = URLRequest(url: requestURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let header = credential.authorizationHeader {
            req.setValue(header, forHTTPHeaderField: "Authorization")
        }
        // An empty title and an empty tag list are *omitted*, not sent
        // empty: ntfy treats an empty `title` as a title and an empty
        // `tags` array as no tags, so both happen to work — but not
        // sending them says what is meant, in a body a human may well end
        // up reading in a server log.
        let title = draft.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        req.httpBody = try JSONEncoder().encode(PublishPayload(
            topic: draft.topic,
            title: (title?.isEmpty == false) ? title : nil,
            message: draft.body,
            priority: draft.priority.rawValue,
            tags: draft.tags.isEmpty ? nil : draft.tags))
        return req
    }

    /// The publish wire format. Optionals are omitted rather than sent as
    /// `null` — Swift's synthesized `encode(to:)` uses `encodeIfPresent`
    /// for an `Optional` property, which is exactly the behaviour wanted
    /// here and the reason this is a `Codable` struct rather than a
    /// hand-built dictionary.
    private struct PublishPayload: Encodable {
        let topic: String
        let title: String?
        let message: String
        let priority: Int
        let tags: [String]?
    }

    /// ntfy's own topic rule, `[-_A-Za-z0-9]{1,64}`.
    private static let allowedTopicCharacters = Set(
        "-_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    )

    /// ntfy's own topic rule, public so the Compose window can show it live
    /// while the user types instead of teaching it with an error after a
    /// round trip. One rule, two readers — this must not drift from
    /// `validate`, which is why `validate` calls this rather than keeping
    /// its own copy.
    public static func isTopicValid(_ topic: String) -> Bool {
        guard (1...64).contains(topic.count) else { return false }
        return topic.allSatisfy(allowedTopicCharacters.contains)
    }

    /// Validates against ntfy's rule rather than against a list of characters
    /// that would break *this* client's URL building. The narrower rule let
    /// through `#` (silently truncating the path at a fragment), whitespace,
    /// and non-ASCII — none of which name a real topic, so a request built
    /// from one can only fail confusingly at the server.
    private func validate(_ topic: String) throws {
        guard Self.isTopicValid(topic) else { throw Error.invalidTopic(topic) }
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
