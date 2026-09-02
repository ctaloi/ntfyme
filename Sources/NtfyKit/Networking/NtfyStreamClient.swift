import Foundation

/// Turns a long-lived ndjson HTTP response into a stream of decoded events.
public struct NtfyStreamClient: Sendable {
    public enum StreamElement: Sendable {
        case event(NtfyEvent)
        /// A line that could not be used. Carries a reason for logging; the
        /// stream continues. Never contains a message body — the reason comes
        /// from `NtfyEventDecoder`'s closed vocabulary, which describes the
        /// failure's shape rather than quoting the line (spec §9).
        case skippedLine(reason: String)
    }

    public enum Error: Swift.Error, Equatable {
        case unauthorized
        case rateLimited(retryAfter: TimeInterval?)
        case invalidSince
        case httpError(status: Int)
    }

    private let session: URLSession
    private let decoder = NtfyEventDecoder()

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func stream(_ request: URLRequest) -> AsyncThrowingStream<StreamElement, Swift.Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    if let error = Self.error(for: response) { throw error }

                    for try await line in bytes.lines {
                        switch decoder.decode(line: line) {
                        case .event(let event):
                            continuation.yield(.event(event))
                        case .ignoredUnknownEvent(let name):
                            continuation.yield(.skippedLine(reason: "unknown event type: \(name)"))
                        case .malformed(let reason):
                            continuation.yield(.skippedLine(reason: "malformed line: \(reason)"))
                        case .empty:
                            continue
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func error(for response: URLResponse) -> Error? {
        guard let http = response as? HTTPURLResponse else { return nil }
        switch http.statusCode {
        case 200..<300:
            return nil
        case 401, 403:
            return .unauthorized
        case 429:
            let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
            return .rateLimited(retryAfter: retryAfter)
        case 400:
            // ntfy returns code 40008 for a malformed `since`; treat any 400 on
            // a subscribe request as that, since it is the only 400 we can cause.
            return .invalidSince
        default:
            return .httpError(status: http.statusCode)
        }
    }
}
