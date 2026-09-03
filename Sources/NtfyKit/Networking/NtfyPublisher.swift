import Foundation

/// Sends a message to an ntfy server.
///
/// The only thing in this project that writes to a server. Everything else
/// runs the other direction: `ServerConnection` → `Ingest` → `MessageStore`.
///
/// Takes the base URL and credential per call rather than holding them,
/// matching `ServerConnection`: the Keychain lookup belongs to the caller
/// that already owns server records, and a publisher that read the Keychain
/// itself could not be tested without one.
public actor NtfyPublisher {
    /// What a publish can fail with, as something a UI can turn into a
    /// sentence. Deliberately carries no response body and no server URL:
    /// per spec §9 a server's hostname is sensitive, and a body is
    /// server-controlled text that has no business in this app's error
    /// surface.
    public enum Error: Swift.Error, Equatable {
        /// 401 or 403 — one case, not two: ntfy returns either depending on
        /// how the server is configured, and the user's next move ("check
        /// the credential for this server") is identical for both.
        case notAuthorized
        /// 404. On ntfy this generally means the server declined the topic
        /// rather than that a URL was mistyped, since any valid topic on a
        /// reachable ntfy server exists by definition.
        case topicRejected
        case tooLarge
        case rateLimited
        case unexpectedStatus(Int)
        /// The response was not HTTP at all. Not reachable against a real
        /// server; present because `URLResponse` is only conditionally an
        /// `HTTPURLResponse` and silently treating that as success would be
        /// the worst possible reading of it.
        case notAnHTTPResponse
    }

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Publishes `draft`, returning once the server has accepted it.
    ///
    /// A transport failure — offline, DNS, TLS — propagates as the
    /// `URLError` it is rather than being folded into `Error`: the caller
    /// already has to distinguish "the server said no" from "there was no
    /// server to ask" for the user, and re-wrapping loses the diagnosis
    /// `URLError` carries for the log.
    public func publish(_ draft: MessageDraft, to baseURL: URL,
                        credential: AuthCredential) async throws {
        let endpoint = NtfyEndpoint(baseURL: baseURL, credential: credential)
        let request = try endpoint.publishRequest(draft)
        let (_, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw Error.notAnHTTPResponse
        }
        switch http.statusCode {
        case 200...299:
            return
        case 401, 403:
            throw Error.notAuthorized
        case 404:
            throw Error.topicRejected
        case 413:
            throw Error.tooLarge
        case 429:
            throw Error.rateLimited
        default:
            throw Error.unexpectedStatus(http.statusCode)
        }
    }
}
