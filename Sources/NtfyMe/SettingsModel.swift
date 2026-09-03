import Foundation
import Observation
import ServiceManagement
import NtfyKit

/// Backs every Settings tab from one shared instance, supplied by the wiring
/// pass with the same `MessageStore`/`PreferencesStore`/`KeychainStore` the
/// rest of the app runs against.
///
/// **Why one instance, not one per tab:** `PreferencesStore.save(_:)` writes
/// all four of its keys unconditionally (`recordOnlyNeverAlert`,
/// `retention.*`, `launchAtLogin`). If General and Notifications each held
/// their own `Preferences` copy loaded at `onAppear`, whichever tab saved
/// second would silently revert whatever the other had just written. Every
/// mutator below instead reloads immediately before writing (see
/// `mutatePreferences`), so a save always starts from the latest value on
/// disk, not a copy that may already be stale.
@MainActor
@Observable
final class SettingsModel {
    private let store: MessageStore
    private let preferences: PreferencesStore
    private let keychain: KeychainStore
    /// Brings live connections into line with the store after a server or
    /// topic change — see `ConnectionCoordinator.sync`'s doc comment for why
    /// this is required at all: a subscription is fixed when a connection
    /// opens, so without this a server or topic added here never connects
    /// until the next relaunch.
    private let syncConnections: @Sendable () async -> Void
    /// Drops and reopens one server's connection — for a credential change,
    /// which `syncConnections` cannot detect because credentials live in the
    /// Keychain, not the stored record `sync()` diffs against.
    private let restartConnection: @Sendable (UUID) async -> Void
    /// Stops one server's connection and awaits its pump before returning —
    /// used by `removeServer` to guarantee nothing is still streaming for a
    /// server before its row (and every message row keyed to it) is purged.
    /// See `removeServer`'s doc comment for why the ordering matters.
    private let closeConnection: @Sendable (UUID) async -> Void
    /// Called after **every** successful store write this model makes, so
    /// other surfaces displaying the same rows — the History window's
    /// sidebar today — re-read instead of continuing to show what they read
    /// before. Wired to `StoreChangeBroadcast.post`; see that type for why
    /// this is one hook for all writes rather than one hook per write.
    ///
    /// The rule for anything added below: if it changed the store and did
    /// not throw, it calls this. A write that failed has nothing for another
    /// surface to learn about, and a write that succeeds silently is the bug
    /// this exists to prevent.
    private let onStoreChanged: @Sendable () async -> Void
    /// Backs `SettingsDefaultsKey`-keyed reads/writes that aren't part of
    /// `Preferences` (that struct and its store are `NtfyKit`, out of this
    /// surface's ownership). Injectable rather than always `.standard` so a
    /// test never reads or writes the real domain — the same isolation
    /// `PreferencesStore(defaults:)` and `KeychainStore(service:)` already
    /// get in every fixture in this file's test target.
    private let defaults: UserDefaults
    /// Where downloaded attachments live — required by `MessageStore
    /// .deleteMessages`/`.removeServer` so a deleted message's or removed
    /// server's downloaded files are actually deleted, not merely
    /// unreferenced. `AppGraph.attachmentsDirectory()` is the single
    /// definition of this path, shared with `RetentionScheduler` and the
    /// History window's Quick Look; this is threaded in rather than
    /// recomputed locally, which is exactly the duplication a review
    /// already collapsed once. `nil` is a legitimate result (Application
    /// Support couldn't be resolved), not an error — see that function's
    /// doc comment.
    private let attachmentsDirectory: @Sendable () -> URL?
    /// Reads `NotificationPresenter.authorizationStatus()`. Not a value read
    /// once at init: it can change any time System Settings is open (see
    /// `refreshNotificationAuthorization`), so this stays a closure the
    /// Notifications tab re-invokes on every appearance.
    private let notificationAuthorizationStatus: @Sendable () async -> SettingsNotificationAuthorization
    /// Reads `NotificationPresenter.requestAuthorization()` — the same
    /// closure shape and the same underlying call `OnboardingView` uses, so
    /// the Notifications tab's "ask now" path for a not-yet-determined
    /// status goes through the identical, single request path rather than a
    /// second one this file invents.
    private let requestNotificationAuthorization: @Sendable () async -> Bool

    private(set) var prefs: Preferences = .default
    /// Read fresh from `SMAppService` rather than derived from
    /// `Preferences.launchAtLogin`: that field is this app's *intent*, but
    /// `SMAppService` is the only source of truth for whether login items are
    /// actually running, including the `.requiresApproval` state
    /// `LoginItem.isEnabled` collapses into `false` (a documented trap — see
    /// `LoginItem.swift`). The General tab surfaces `.requiresApproval`
    /// distinctly rather than showing an unexplained "off".
    private(set) var loginItemStatus: SMAppService.Status = .notFound

    private(set) var servers: [ServerRecordSnapshot] = []
    private(set) var topicSummaries: [TopicSummary] = []
    private(set) var isLoadingServers = false

    private(set) var messageCount = 0

    /// What the Notifications tab actually shows — see
    /// `refreshNotificationAuthorization`. Starts `.notDetermined` rather
    /// than a made-up "unknown" case: that is the honest default before the
    /// first read completes, and it is also a real status this type has to
    /// represent regardless.
    private(set) var notificationAuthorization: SettingsNotificationAuthorization = .notDetermined

    /// The one error channel every mutator below writes to. Set, never
    /// silently dropped — an alert bound to this in `SettingsView` is the
    /// user-visible half of "no silent failures" (spec §10); `Log.app` calls
    /// alongside it are the diagnostic half, and per `Log.swift` carry only a
    /// literal plus an `NSError`'s `domain`/`code`, never the underlying
    /// description, a hostname, or a topic.
    var errorMessage: String?

    init(store: MessageStore, preferences: PreferencesStore, keychain: KeychainStore,
         syncConnections: @escaping @Sendable () async -> Void = {},
         restartConnection: @escaping @Sendable (UUID) async -> Void = { _ in },
         closeConnection: @escaping @Sendable (UUID) async -> Void = { _ in },
         defaults: UserDefaults = .standard,
         attachmentsDirectory: @escaping @Sendable () -> URL? = { nil },
         notificationAuthorizationStatus: @escaping @Sendable () async -> SettingsNotificationAuthorization = { .notDetermined },
         requestNotificationAuthorization: @escaping @Sendable () async -> Bool = { false },
         onStoreChanged: @escaping @Sendable () async -> Void = {}) {
        self.store = store
        self.preferences = preferences
        self.keychain = keychain
        self.syncConnections = syncConnections
        self.restartConnection = restartConnection
        self.closeConnection = closeConnection
        self.defaults = defaults
        self.attachmentsDirectory = attachmentsDirectory
        self.notificationAuthorizationStatus = notificationAuthorizationStatus
        self.requestNotificationAuthorization = requestNotificationAuthorization
        self.onStoreChanged = onStoreChanged
    }

    func refresh() async {
        refreshPreferences()
        await loadServers()
        await refreshMessageCount()
    }

    // MARK: - Preferences

    func refreshPreferences() {
        prefs = preferences.load()
        loginItemStatus = SMAppService.mainApp.status
    }

    // MARK: - Notification authorization

    /// Re-reads the system's current answer. Not read once and cached: the
    /// user can flip it in System Settings while this window is open, so
    /// `SettingsNotificationsTab` calls this on every appearance rather than
    /// once at construction.
    func refreshNotificationAuthorization() async {
        notificationAuthorization = await notificationAuthorizationStatus()
    }

    /// The Notifications tab's "ask now" action for a `.notDetermined`
    /// status — offering to request permission directly rather than sending
    /// the user to System Settings for a prompt the app has not made yet.
    /// Re-reads the status afterward so the tab reflects the system's
    /// answer immediately instead of waiting for the next appearance.
    func enableNotifications() async {
        _ = await requestNotificationAuthorization()
        await refreshNotificationAuthorization()
    }

    /// Reload-mutate-save, see the type's doc comment for why every write
    /// goes through this rather than saving a held copy.
    private func mutatePreferences(_ mutate: (inout Preferences) -> Void) {
        var current = preferences.load()
        mutate(&current)
        preferences.save(current)
        prefs = current
    }

    func setRecordOnlyNeverAlert(_ value: Bool) {
        mutatePreferences { $0.recordOnlyNeverAlert = value }
    }

    func setRetention(days: Int, maxMessagesPerTopic: Int) {
        do {
            let policy = try SettingsRetentionValidation.validate(
                days: days, maxMessagesPerTopic: maxMessagesPerTopic)
            mutatePreferences { $0.retention = policy }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// `SMAppService.register()`/`unregister()` are synchronous and throwing
    /// — no `await` here is not a shortcut, there is nothing to await.
    /// `loginItemStatus` is re-read after the call rather than assumed from
    /// `enabled`, because registering does not guarantee `.enabled`; it can
    /// land in `.requiresApproval` instead (see this type's doc comment).
    /// `Preferences.launchAtLogin` — the intent flag — is still updated
    /// unconditionally, so a relaunch that finds the item pending approval
    /// still remembers the user asked for it.
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.setEnabled(enabled)
        } catch {
            let ns = error as NSError
            Log.app.error("launch-at-login change failed: \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
            errorMessage = "Couldn't change launch-at-login: \(ns.localizedDescription)"
        }
        mutatePreferences { $0.launchAtLogin = enabled }
        loginItemStatus = SMAppService.mainApp.status
    }

    // MARK: - Servers

    func loadServers() async {
        isLoadingServers = true
        defer { isLoadingServers = false }
        do {
            servers = try await store.servers()
            topicSummaries = try await store.topicSummaries()
        } catch {
            let ns = error as NSError
            Log.app.error("failed to load servers: \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
            errorMessage = "Couldn't load servers: \(ns.localizedDescription)"
        }
    }

    func topics(for serverID: UUID) -> [TopicSummary] {
        topicSummaries.filter { $0.serverID == serverID }
    }

    /// Seeds `https://ntfy.sh` — ntfy's own public instance — as a starting
    /// point on a genuinely new install, so a new user does not need to
    /// already know the public server's address before Settings → Servers
    /// has anything to click on.
    ///
    /// Added with **no topics**, which is the load-bearing half: a server
    /// with no topics opens no connection at all
    /// (`ConnectionCoordinator.sync`'s `wanted` set filters on
    /// `!topics.isEmpty`), so this subscribes the user to nothing and starts
    /// no network activity — it only removes the "what do I type here" step.
    /// `syncConnections()` is deliberately not called here for the same
    /// reason: there is nothing for it to do.
    ///
    /// **Two guards, not one, because they protect against two different
    /// histories.** `SettingsDefaultsKey.hasSeededDefaultServer` (see its
    /// doc comment) stops a re-seed after a user deliberately removes the
    /// seeded row. The base-URL check below stops something else: an
    /// install that already had `https://ntfy.sh` configured — added by
    /// hand, before this method existed — where the flag has never been
    /// set. Without it, every such install seeds a *second*
    /// `https://ntfy.sh` row the first time this runs. That is not
    /// cosmetic: two `Server` rows at the same base URL are two
    /// `ServerConnection`s once a topic is added to either, so two streams,
    /// two inserts racing on the same `uniqueKey`, and — dedup being
    /// per-row — plausibly two notifications for every message. Compared
    /// with a normalized form (scheme and host lowercased, no trailing
    /// slash) so `https://ntfy.sh/` or `https://NTFY.SH` still count as
    /// already present.
    ///
    /// Called from `SettingsView`'s `.task`, so this runs once per
    /// Settings-window open — cheap enough (one `store.servers()` call) to
    /// not bother caching that it already ran within a session.
    func seedDefaultServerIfNeeded() async {
        guard !defaults.bool(forKey: SettingsDefaultsKey.hasSeededDefaultServer) else { return }

        let seedURL = URL(string: "https://ntfy.sh")!
        let seedKey = Self.normalizedBaseURLKey(seedURL)

        do {
            let existing = try await store.servers()
            if existing.contains(where: { Self.normalizedBaseURLKey($0.baseURL) == seedKey }) {
                // Already configured, just not by this method — most likely
                // added by hand before this flag existed. Recorded as done
                // without adding a duplicate.
                defaults.set(true, forKey: SettingsDefaultsKey.hasSeededDefaultServer)
                return
            }
            _ = try await store.addServer(
                name: "ntfy.sh", baseURL: seedURL,
                authKindRaw: SettingsCredentialKind.unauthenticated.rawValue)
        } catch {
            // Not marked seeded: a transient failure here (e.g. the store
            // was briefly unavailable) should retry on the next launch
            // rather than being recorded as permanently done.
            let ns = error as NSError
            Log.app.error("seeding default server failed: \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
            return
        }

        defaults.set(true, forKey: SettingsDefaultsKey.hasSeededDefaultServer)
        await onStoreChanged()
        await loadServers()
    }

    /// A same-server comparison key: scheme and host lowercased, no trailing
    /// slash. Exists solely so `seedDefaultServerIfNeeded` can recognize
    /// `https://ntfy.sh`, `https://ntfy.sh/`, and `https://NTFY.SH` as the
    /// same server rather than three different ones.
    private static func normalizedBaseURLKey(_ url: URL) -> String {
        let scheme = (url.scheme ?? "").lowercased()
        let host = (url.host ?? "").lowercased()
        let port = url.port.map { ":\($0)" } ?? ""
        var path = url.path
        while path.hasSuffix("/") { path.removeLast() }
        return "\(scheme)://\(host)\(port)\(path)"
    }

    /// Adds a server and its credential together. If the credential fails to
    /// save, the just-created server row is removed rather than left behind
    /// claiming a kind (`authKindRaw`) the Keychain does not actually hold —
    /// an orphaned row is worse than no row, because every future connection
    /// attempt for it would silently run unauthenticated instead of failing
    /// visibly.
    func addServer(name: String, baseURL: URL, kind: SettingsCredentialKind,
                   credential: AuthCredential) async -> Bool {
        let id: UUID
        do {
            id = try await store.addServer(name: name, baseURL: baseURL, authKindRaw: kind.rawValue)
        } catch {
            let ns = error as NSError
            Log.app.error("addServer failed: \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
            errorMessage = "Couldn't add the server: \(ns.localizedDescription)"
            return false
        }

        do {
            try keychain.save(credential, forServer: id)
        } catch {
            let ns = error as NSError
            Log.app.error("keychain save failed for server \(id.uuidString, privacy: .public): \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
            do {
                // `attachmentsDirectory: nil` is correct here, not just
                // convenient: `syncConnections()` is never called before
                // this rollback runs, so `ConnectionCoordinator` never knew
                // this server existed and never opened a connection for it —
                // there is provably no message, and so no attachment file,
                // for `id` to delete.
                try await store.removeServer(id, attachmentsDirectory: nil)
            } catch {
                let rollbackNS = error as NSError
                Log.app.error("rollback removeServer failed for server \(id.uuidString, privacy: .public): \(rollbackNS.domain, privacy: .public) \(rollbackNS.code, privacy: .public)")
            }
            errorMessage = "Couldn't save the credential to the Keychain, so the server was not added."
            return false
        }

        // A subscription is fixed when a connection opens (see
        // `ConnectionCoordinator.sync`'s doc comment), so without this the
        // server just added would never connect until the next relaunch —
        // the entire fresh-install path would produce no messages, no
        // error, and no hint that a relaunch was needed.
        await syncConnections()
        await onStoreChanged()
        await loadServers()
        return true
    }

    /// Rotates a server's credential in place. `authKindRaw` on the stored
    /// row is not updated — `MessageStore` has no method for that today —
    /// but this still takes effect for every future connection: reading
    /// `ConnectionCoordinator.open` shows it loads the credential from the
    /// Keychain and decodes its *own* stored kind, and never consults
    /// `authKindRaw` at all. Only the row's displayed kind label can go
    /// stale after a kind change; see the wave2-settings report for the
    /// `MessageStore` API this needs to fix that display gap.
    func updateCredential(serverID: UUID, credential: AuthCredential) async -> Bool {
        do {
            try keychain.save(credential, forServer: serverID)
            // Not `syncConnections()`: the stored `Server` record is
            // unchanged by a credential rotation, so `sync()` would
            // correctly see nothing to diff and the live connection would
            // keep using the old credential until a relaunch. `restart`
            // exists specifically for this — it re-reads the Keychain.
            await restartConnection(serverID)
            return true
        } catch {
            let ns = error as NSError
            Log.app.error("keychain save failed for server \(serverID.uuidString, privacy: .public): \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
            errorMessage = "Couldn't save the credential."
            return false
        }
    }

    /// Close, then purge, then sync — in that order, deliberately.
    /// `store.removeServer` purges the `Server` row and every `Message` for
    /// it in one call, and `Message.serverID` is a bare UUID rather than a
    /// relationship the purge could block on — so a message the connection
    /// received *after* the purge but before it was told to stop would still
    /// insert successfully, as an orphan row nothing could ever clean up
    /// again (this method can no longer look the server up once its row is
    /// gone). `closeConnection` awaits the connection's pump before
    /// returning, which is what actually closes that window: nothing can be
    /// mid-flight for this server once the purge below runs.
    /// `syncConnections()` afterwards is not redundant with `closeConnection`
    /// — it reconciles anything else that changed while this call was in
    /// flight, the same as every other mutator in this file.
    ///
    /// `MessageStore.removeServer` does not touch the Keychain — its doc
    /// comment is explicit that credentials are the caller's responsibility
    /// — so the explicit `keychain.delete` below is required, not optional:
    /// skipping it would leave a stale credential in the Keychain forever,
    /// keyed by a server UUID nothing can look up again. The real
    /// `attachmentsDirectory()` is passed for the same reason, not `nil`:
    /// this server's messages are gone after this call, so nothing could
    /// ever look up their downloaded attachment files again either.
    func removeServer(_ serverID: UUID) async {
        await closeConnection(serverID)

        do {
            try await store.removeServer(serverID, attachmentsDirectory: attachmentsDirectory())
        } catch {
            let ns = error as NSError
            Log.app.error("removeServer failed: \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
            errorMessage = "Couldn't remove the server: \(ns.localizedDescription)"
            // The connection was already closed above even though the purge
            // failed. Reopening it is `syncConnections()`'s job — the store
            // still lists this server, so a sync resumes it rather than
            // leaving it dark until the next relaunch.
            await syncConnections()
            return
        }
        do {
            try keychain.delete(forServer: serverID)
        } catch {
            let ns = error as NSError
            Log.app.error("keychain delete failed for server \(serverID.uuidString, privacy: .public): \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
            errorMessage = "The server was removed, but its saved credential could not be deleted from the Keychain."
        }
        await syncConnections()
        await onStoreChanged()
        await loadServers()
    }

    func addTopic(_ topic: String, toServer serverID: UUID) async {
        do {
            try await store.addTopic(topic, toServer: serverID)
        } catch {
            let ns = error as NSError
            Log.app.error("addTopic failed: \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
            errorMessage = "Couldn't add the topic: \(ns.localizedDescription)"
            return
        }

        // Seeds the Notifications tab's "Minimum priority" default onto the
        // row `store.addTopic` just created, which otherwise defaults to 1
        // (alert on everything) — see `Subscription.init`. Not folded into
        // the failure path above: the topic was already added successfully,
        // so a failure here is a mismatch from the user's stated default,
        // not a lost topic, and it fails toward "alerts on everything"
        // rather than toward silently dropping notifications — the safer
        // direction — so it is logged rather than surfaced as a blocking
        // error over an action that actually succeeded.
        do {
            try await store.setAlertSettings(
                TopicAlertSettings(muted: false, minAlertPriority: defaultMinAlertPriority()),
                forServer: serverID, topic: topic)
        } catch {
            let ns = error as NSError
            Log.app.error("seeding default alert priority failed: \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
        }

        // A live connection's subscription is fixed at connect time, so
        // adding a topic to an already-connected server needs a reconnect
        // to actually start receiving it — `sync()` is what does that.
        await syncConnections()
        // The reported bug: without this the topic is in the store, its
        // messages arrive and are listed, and the History sidebar never
        // shows it at all.
        await onStoreChanged()
        await loadServers()
    }

    /// Mirrors `SettingsNotificationsTab`'s `@AppStorage(SettingsDefaultsKey
    /// .defaultMinPriority)` fallback. `SettingsModel` is a plain class, not
    /// a `View`, so it cannot use `@AppStorage` itself — and
    /// `UserDefaults.integer(forKey:)` returns `0` for a key nobody has
    /// written yet, not that wrapper's Swift-side default, so `0` (not a
    /// valid `NtfyPriority`) has to be mapped back to the same
    /// `NtfyPriority.default` the picker starts on.
    private func defaultMinAlertPriority() -> Int {
        let stored = defaults.integer(forKey: SettingsDefaultsKey.defaultMinPriority)
        return NtfyPriority(rawValue: stored)?.rawValue ?? NtfyPriority.default.rawValue
    }

    func removeTopic(_ topic: String, fromServer serverID: UUID) async {
        do {
            try await store.removeTopic(topic, fromServer: serverID)
        } catch {
            let ns = error as NSError
            Log.app.error("removeTopic failed: \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
            errorMessage = "Couldn't remove the topic: \(ns.localizedDescription)"
            return
        }
        await syncConnections()
        await onStoreChanged()
        await loadServers()
    }

    func setAlertSettings(_ settings: TopicAlertSettings, serverID: UUID, topic: String) async {
        do {
            try await store.setAlertSettings(settings, forServer: serverID, topic: topic)
        } catch {
            let ns = error as NSError
            Log.app.error("setAlertSettings failed: \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
            errorMessage = "Couldn't update the topic's alert settings."
            return
        }
        await onStoreChanged()
        await loadServers()
    }

    // MARK: - Test connection

    enum ConnectionTestResult: Equatable {
        case reachable
        case unauthorized
        case unexpectedStatus(Int)
        case failed(String)
    }

    /// A lightweight reachability check against ntfy's own `/v1/health`
    /// endpoint. Never logged: the URL is the server's address, which spec
    /// §9 treats the same as a hostname or topic name anywhere else in this
    /// app. Only the user-facing `ConnectionTestResult` — a status, never
    /// the request itself — reaches the caller, and it is shown in the
    /// editor sheet, not written to `Log`.
    func testConnection(baseURL: URL, credential: AuthCredential) async -> ConnectionTestResult {
        var request = URLRequest(url: baseURL.appending(path: "v1/health"))
        request.timeoutInterval = 8
        if let header = credential.authorizationHeader {
            request.setValue(header, forHTTPHeaderField: "Authorization")
        }
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed("The server did not return a valid HTTP response.")
            }
            switch http.statusCode {
            case 200..<300: return .reachable
            case 401, 403: return .unauthorized
            default: return .unexpectedStatus(http.statusCode)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Advanced

    func refreshMessageCount() async {
        do {
            messageCount = try await store.messageCount()
        } catch {
            let ns = error as NSError
            Log.app.error("messageCount failed: \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
        }
    }

    /// Pages through the whole archive rather than issuing one huge
    /// `MessageQuery.limit` — the query has no "give me everything" mode and
    /// defaults to 200 rows per call. JSON encoding of the result happens
    /// entirely off this call (the Advanced tab wraps it in
    /// `Task.detached`), which is what actually satisfies spec §7's "must
    /// not block the main thread on a large archive" — this method alone,
    /// running on `MessageStore`'s own actor, was never on the main thread
    /// to begin with.
    func fetchAllMessages() async throws -> [MessageSnapshot] {
        var all: [MessageSnapshot] = []
        var offset = 0
        let pageSize = 500
        while true {
            let page = try await store.search(MessageQuery(limit: pageSize, offset: offset))
            all.append(contentsOf: page)
            guard page.count == pageSize else { break }
            offset += pageSize
        }
        return all
    }

    /// Deletes every stored message but leaves every server — and its
    /// Keychain credential — untouched. "Clear data" reads as "clear the
    /// archive you built up", not "un-configure the app"; removing servers
    /// too would also strand their Keychain entries the way a bare
    /// `removeServer` without a matching `keychain.delete` would (see
    /// `removeServer` above). Always re-fetches at offset 0: each delete
    /// shrinks the table, so the next page is whatever slid into the rows
    /// just cleared, not whatever used to sit past them.
    ///
    /// Passes the real `attachmentsDirectory()`, not `nil`: a "clear data"
    /// button that deletes every message row but leaves every downloaded
    /// attachment file behind is not actually clearing the data.
    func clearAllMessages() async {
        do {
            while true {
                let page = try await store.search(MessageQuery(limit: 500, offset: 0))
                guard !page.isEmpty else { break }
                try await store.deleteMessages(page.map(\.id), attachmentsDirectory: attachmentsDirectory())
            }
        } catch {
            let ns = error as NSError
            Log.app.error("clearAllMessages failed: \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
            errorMessage = "Couldn't clear history: \(ns.localizedDescription)"
        }
        // Outside the `do`, unlike every other write here: this loop deletes
        // a page at a time, so a throw on the third page leaves the first two
        // genuinely deleted. Posting only on total success would leave every
        // other surface showing messages that are gone.
        await onStoreChanged()
        await refreshMessageCount()
    }
}
