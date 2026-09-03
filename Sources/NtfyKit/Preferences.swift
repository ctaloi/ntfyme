import Foundation

/// App-wide settings. Per-topic settings live on `Subscription` in the store;
/// only what is genuinely global is here.
public struct Preferences: Sendable, Equatable {
    /// Spec §6's global suppression: persist every message, raise nothing.
    public var recordOnlyNeverAlert: Bool
    public var retention: RetentionPolicy
    public var launchAtLogin: Bool

    public static let `default` = Preferences(
        recordOnlyNeverAlert: false, retention: .default, launchAtLogin: false)

    public init(recordOnlyNeverAlert: Bool, retention: RetentionPolicy, launchAtLogin: Bool) {
        self.recordOnlyNeverAlert = recordOnlyNeverAlert
        self.retention = retention
        self.launchAtLogin = launchAtLogin
    }
}

/// `UserDefaults`-backed storage for `Preferences`.
///
/// `UserDefaults` itself is not marked `Sendable` on this SDK, but Apple's
/// documentation guarantees it is safe to use concurrently from multiple
/// threads, so `@unchecked Sendable` here is asserting a fact the compiler
/// cannot see, not bypassing an actual data race.
public final class PreferencesStore: @unchecked Sendable {
    private enum Key {
        static let recordOnly = "recordOnlyNeverAlert"
        static let maxAge = "retention.maxAge"
        static let maxPerTopic = "retention.maxMessagesPerTopic"
        static let launchAtLogin = "launchAtLogin"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> Preferences {
        let age = defaults.double(forKey: Key.maxAge)
        let perTopic = defaults.integer(forKey: Key.maxPerTopic)
        // Zero means either "never written" or a corrupt value; both take the
        // default. A retention window of zero would delete everything on the
        // next prune, which is never what a user meant.
        let retention = (age > 0 && perTopic > 0)
            ? RetentionPolicy(maxAge: age, maxMessagesPerTopic: perTopic)
            : .default

        return Preferences(
            recordOnlyNeverAlert: defaults.bool(forKey: Key.recordOnly),
            retention: retention,
            launchAtLogin: defaults.bool(forKey: Key.launchAtLogin))
    }

    public func save(_ prefs: Preferences) {
        defaults.set(prefs.recordOnlyNeverAlert, forKey: Key.recordOnly)
        defaults.set(prefs.retention.maxAge, forKey: Key.maxAge)
        defaults.set(prefs.retention.maxMessagesPerTopic, forKey: Key.maxPerTopic)
        defaults.set(prefs.launchAtLogin, forKey: Key.launchAtLogin)
    }
}
