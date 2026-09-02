import Foundation

/// Why a connection is degraded, in a closed vocabulary.
///
/// Deliberately not a free-form `String`. The obvious implementation —
/// `String(describing: error)` — puts a Foundation error's description into a
/// value that `ConnectionState` says drives the menu bar icon, and is therefore
/// destined for the UI and for logs. A `URLError`'s description carries
/// `NSErrorFailingURLStringKey`, which is the full subscribe URL: every
/// subscribed topic name and the server host. Topic names are effectively
/// passwords on public ntfy.sh and self-hosted hostnames are sensitive
/// (spec §9), so nothing derived from an error's text reaches this type.
///
/// The closed vocabulary is also what the UI needs: "rate limited" and
/// "history gap" and "offline" call for different presentation, and branching
/// on a string is not a design.
public enum DegradedReason: Sendable, Equatable {
    /// The transport failed. See `NetworkFailure` for the classification.
    case network(NetworkFailure)
    /// HTTP 429. The connection is waiting out the server's `Retry-After`.
    case rateLimited
    /// The resume watermark predates the server's cache window, so the server
    /// is replaying its whole cache and some messages are unrecoverable
    /// (spec §10).
    case historyGap
    /// No line — message or keepalive — arrived within the watchdog timeout.
    case keepaliveTimeout
    /// The server rejected the `since` value this client built. A client bug;
    /// the next attempt falls back to `since=all` (spec §10).
    case invalidSince
    /// An HTTP status with no more specific meaning to this client.
    case httpError(status: Int)
    /// An error that is neither a `URLError` nor a `NtfyStreamClient.Error`.
    /// Carries nothing: an unrecognized error is exactly the case where its
    /// description is least predictable and most likely to embed a URL.
    case unclassified

    /// Transport failure, identified without quoting anything the error said.
    public enum NetworkFailure: Sendable, Equatable {
        case offline
        case timedOut
        case cannotConnect
        case cannotFindHost
        case connectionLost
        case secureConnectionFailed
        case cancelled
        /// Any other `URLError`, identified by its numeric code alone. A code
        /// is a fixed constant, so it can carry nothing from the request.
        case other(code: Int)
    }
}

extension DegradedReason {
    /// Maps a thrown error onto the closed vocabulary. The single place an
    /// error is allowed to influence connection state, and it reads only the
    /// error's *type* and numeric code — never its description.
    static func classify(_ error: Swift.Error) -> DegradedReason {
        switch error {
        case let error as NtfyStreamClient.Error:
            switch error {
            case .rateLimited:
                return .rateLimited
            case .invalidSince:
                return .invalidSince
            case .httpError(let status):
                return .httpError(status: status)
            case .unauthorized:
                // Not reachable from the generic catch: `runLoop` has its own
                // branch for 401/403 and never degrades on it. Mapped rather
                // than trapped, because a state machine is not worth crashing
                // an app over if that branch is ever reordered.
                return .unclassified
            }
        case let error as URLError:
            return .network(NetworkFailure(error.code))
        default:
            return .unclassified
        }
    }

    /// A short, fixed label for logging. Every branch returns a string
    /// literal or an integer, so no caller-supplied text can pass through.
    var logLabel: String {
        switch self {
        case .network(let failure): "network: \(failure.logLabel)"
        case .rateLimited: "rate limited"
        case .historyGap: "history gap"
        case .keepaliveTimeout: "keepalive timeout"
        case .invalidSince: "invalid since parameter"
        case .httpError(let status): "http \(status)"
        case .unclassified: "unclassified error"
        }
    }
}

extension DegradedReason.NetworkFailure {
    init(_ code: URLError.Code) {
        switch code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            self = .offline
        case .timedOut:
            self = .timedOut
        case .cannotConnectToHost:
            self = .cannotConnect
        case .cannotFindHost, .dnsLookupFailed:
            self = .cannotFindHost
        case .networkConnectionLost:
            self = .connectionLost
        case .secureConnectionFailed, .serverCertificateUntrusted,
             .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot, .clientCertificateRejected,
             .clientCertificateRequired:
            self = .secureConnectionFailed
        case .cancelled:
            self = .cancelled
        default:
            self = .other(code: code.rawValue)
        }
    }

    var logLabel: String {
        switch self {
        case .offline: "offline"
        case .timedOut: "timed out"
        case .cannotConnect: "cannot connect to host"
        case .cannotFindHost: "cannot find host"
        case .connectionLost: "connection lost"
        case .secureConnectionFailed: "tls failure"
        case .cancelled: "cancelled"
        case .other(let code): "urlerror \(code)"
        }
    }
}

/// Observable state of one server's connection. Drives the menu bar icon.
public enum ConnectionState: Sendable, Equatable {
    case idle
    case connecting
    case open
    case degraded(reason: DegradedReason)
    case backoff(attempt: Int)
    /// Terminal until credentials change: retrying a rejected credential only
    /// burns rate limit.
    case unauthorized
}
