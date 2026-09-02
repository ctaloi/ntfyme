import Foundation

/// Builds requests against one ntfy server.
public struct NtfyEndpoint: Sendable {
    public enum Error: Swift.Error, Equatable {
        case noTopics
        case invalidTopic(String)
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
        return request(path: topics.joined(separator: ","), query: items)
    }

    /// One-shot fetch used to backfill a newly added topic.
    public func pollRequest(topic: String, since: SinceParameter) throws -> URLRequest {
        try validate(topic)
        return request(path: topic, query: [
            URLQueryItem(name: "poll", value: "1"),
            URLQueryItem(name: "since", value: since.queryValue),
        ])
    }

    private func validate(_ topic: String) throws {
        guard !topic.isEmpty,
              !topic.contains(","),
              !topic.contains("/"),
              !topic.contains("?")
        else { throw Error.invalidTopic(topic) }
    }

    private func request(path: String, query: [URLQueryItem]) -> URLRequest {
        let url = baseURL.appending(path: path).appending(path: "json")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }

        var req = URLRequest(url: components.url!)
        req.httpMethod = "GET"
        if let header = credential.authorizationHeader {
            req.setValue(header, forHTTPHeaderField: "Authorization")
        }
        return req
    }
}
