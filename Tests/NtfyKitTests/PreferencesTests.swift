import Foundation
import Testing
@testable import NtfyKit

private func isolatedDefaults() -> UserDefaults {
    // A per-test suite name so tests never read or write the real app domain.
    UserDefaults(suiteName: "dev.aloi.NtfyMe.tests.\(UUID().uuidString)")!
}

@Test func defaultsMatchTheSpec() {
    let prefs = PreferencesStore(defaults: isolatedDefaults()).load()
    #expect(prefs.recordOnlyNeverAlert == false)
    #expect(prefs.retention == .default)          // 30 days / 10_000 per topic
    #expect(prefs.launchAtLogin == false)
}

@Test func preferencesRoundTrip() {
    let store = PreferencesStore(defaults: isolatedDefaults())
    let prefs = Preferences(
        recordOnlyNeverAlert: true,
        retention: RetentionPolicy(maxAge: 7 * 86_400, maxMessagesPerTopic: 500),
        launchAtLogin: true)
    store.save(prefs)
    #expect(store.load() == prefs)
}

/// A stored value of zero or less is corrupt, not "keep nothing".
@Test func nonsensicalStoredRetentionFallsBackToTheDefault() {
    let defaults = isolatedDefaults()
    defaults.set(0.0, forKey: "retention.maxAge")
    defaults.set(0, forKey: "retention.maxMessagesPerTopic")
    let prefs = PreferencesStore(defaults: defaults).load()
    #expect(prefs.retention == .default)
}
