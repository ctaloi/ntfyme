import Foundation
import NtfyKit

/// Turns the messages `Ingest` **stored** into notifications.
///
/// This is the consumer end of `Ingest.StoredHandler`, and the only place the
/// pure `NotificationDecision` meets the system's notification centre. It
/// holds no policy of its own: it reads the settings a decision needs, asks
/// `NotificationDecision`, and hands a `.present` to the presenter.
///
/// Notifying from what was stored, rather than from what arrived, is the same
/// rule §5.2 applies to the resume point: a notification for a message that is
/// not in the archive is one the user cannot go back and find, and a failed
/// insert must not produce a phantom alert. A duplicate replayed on reconnect
/// is not in `Ingest`'s stored batch, so it cannot notify twice.
@MainActor
final class NotificationRouter {
    private let store: MessageStore
    private let preferences: PreferencesStore
    private let presenter: NotificationPresenter

    init(store: MessageStore, preferences: PreferencesStore,
         presenter: NotificationPresenter) {
        self.store = store
        self.preferences = preferences
        self.presenter = presenter
    }

    /// Decides and presents, one stored message at a time.
    ///
    /// Serial rather than concurrent: notifications arrive in the order the
    /// stream delivered them, and `NotificationPresenter.registerCategory`
    /// already serializes itself, so concurrency here would buy nothing but a
    /// scrambled banner order.
    func handleStored(_ events: [NtfyEvent], serverID: UUID) async {
        // Once per batch, not once per event: `load()` is a handful of
        // `UserDefaults` reads, and a preference change landing mid-batch is
        // a distinction of milliseconds that no user can perceive.
        let preferences = preferences.load()
        // Same reasoning, and it also saves a store round trip per message:
        // a batch is usually many messages on a handful of topics.
        var settingsByTopic: [String: TopicAlertSettings] = [:]

        for event in events {
            let settings: TopicAlertSettings
            if let cached = settingsByTopic[event.topic] {
                settings = cached
            } else {
                do {
                    settings = try await store.alertSettings(
                        forServer: serverID, topic: event.topic)
                } catch {
                    // Not notified, and not silent. This is deliberately the
                    // opposite default from `alertSettings`'s own missing-row
                    // fallback, because the two say different things: an
                    // absent row means the user never expressed a preference,
                    // so the safe answer is the one that does not hide a
                    // message. A *throwing* fetch means the store could not
                    // answer at all — and a store that cannot say whether a
                    // topic is muted cannot be trusted to say that it isn't.
                    // The message is in the archive either way.
                    //
                    // Domain and code only: a SwiftData error's description
                    // can embed a stored value, and every stored value here is
                    // a body, a topic, or a messageID (see `Log`).
                    let ns = error as NSError
                    Log.app.error("alert settings unavailable; not notifying for this message: \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
                    continue
                }
                settingsByTopic[event.topic] = settings
            }

            switch NotificationDecision.decide(event: event, serverID: serverID,
                                               settings: settings,
                                               preferences: preferences) {
            case .present(let request):
                await presenter.present(request)
            case .suppress:
                // Not logged. Suppression is the *normal* outcome of a mute, a
                // priority floor, or the global record-only toggle — the user
                // asked for it — and the message is stored either way. A log
                // line per suppressed message would be noise, and the only
                // detail that would make it useful is the topic, which must
                // never be logged (see `Log`).
                break
            }
        }
    }
}
