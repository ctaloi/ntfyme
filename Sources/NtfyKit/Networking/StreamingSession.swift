import Foundation

/// A `URLSession` configured for connections that are supposed to stay open
/// for days.
///
/// `URLSession.shared` is wrong here in two ways. Its 60-second
/// `timeoutIntervalForRequest` is shorter than the 90-second keepalive
/// watchdog, so a stalled connection surfaces as a `URLError` before the
/// watchdog can classify it — inverting the primary liveness signal spec §5
/// specifies. And its 7-day `timeoutIntervalForResource` would end every
/// stream weekly for no reason the user could see.
public enum StreamingSession {
    /// For SUBSCRIPTIONS only. These timeouts are deliberately long because a
    /// subscription is meant to stay open for days — which makes them exactly
    /// wrong for a one-shot poll. `Backfill` bounds its own wait locally and
    /// must not rely on this session's limits.
    public static func make() -> URLSession {
        let configuration = URLSessionConfiguration.default
        // Comfortably longer than the watchdog, so the watchdog decides.
        configuration.timeoutIntervalForRequest = 300
        // Effectively unbounded: the stream ends when the app or server says so.
        configuration.timeoutIntervalForResource = 365 * 86_400
        configuration.waitsForConnectivity = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }
}
