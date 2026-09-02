import Foundation

/// The `since=` query parameter. Measured behavior (spec §5): a timestamp is a
/// lower bound, a well-formed but unknown message ID silently returns the whole
/// cache, and a malformed value is rejected with HTTP 400 code 40008.
public enum SinceParameter: Sendable, Equatable {
    case all
    case unixTime(Int)
    case messageID(String)
    case duration(String)

    public var queryValue: String {
        switch self {
        case .all: "all"
        case .unixTime(let t): String(t)
        case .messageID(let id): id
        case .duration(let d): d
        }
    }
}
