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

    /// The one error channel every mutator below writes to. Set, never
    /// silently dropped — an alert bound to this in `SettingsView` is the
    /// user-visible half of "no silent failures" (spec §10); `Log.app` calls
    /// alongside it are the diagnostic half, and per `Log.swift` carry only a
    /// literal plus an `NSError`'s `domain`/`code`, never the underlying
    /// description, a hostname, or a topic.
    var errorMessage: String?

    init(store: MessageStore, preferences: PreferencesStore, keychain: KeychainStore) {
        self.store = store
        self.preferences = preferences
        self.keychain = keychain
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
                try await store.removeServer(id)
            } catch {
                let rollbackNS = error as NSError
                Log.app.error("rollback removeServer failed for server \(id.uuidString, privacy: .public): \(rollbackNS.domain, privacy: .public) \(rollbackNS.code, privacy: .public)")
            }
            errorMessage = "Couldn't save the credential to the Keychain, so the server was not added."
            return false
        }

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
            return true
        } catch {
            let ns = error as NSError
            Log.app.error("keychain save failed for server \(serverID.uuidString, privacy: .public): \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
            errorMessage = "Couldn't save the credential."
            return false
        }
    }

    /// `MessageStore.removeServer` does not touch the Keychain — its doc
    /// comment is explicit that credentials are the caller's responsibility
    /// — so the explicit `keychain.delete` below is required, not optional:
    /// skipping it would leave a stale credential in the Keychain forever,
    /// keyed by a server UUID nothing can look up again.
    func removeServer(_ serverID: UUID) async {
        do {
            try await store.removeServer(serverID)
        } catch {
            let ns = error as NSError
            Log.app.error("removeServer failed: \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
            errorMessage = "Couldn't remove the server: \(ns.localizedDescription)"
            return
        }
        do {
            try keychain.delete(forServer: serverID)
        } catch {
            let ns = error as NSError
            Log.app.error("keychain delete failed for server \(serverID.uuidString, privacy: .public): \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
            errorMessage = "The server was removed, but its saved credential could not be deleted from the Keychain."
        }
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
        await loadServers()
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
    func clearAllMessages() async {
        do {
            while true {
                let page = try await store.search(MessageQuery(limit: 500, offset: 0))
                guard !page.isEmpty else { break }
                try await store.deleteMessages(page.map(\.id))
            }
        } catch {
            let ns = error as NSError
            Log.app.error("clearAllMessages failed: \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
            errorMessage = "Couldn't clear history: \(ns.localizedDescription)"
        }
        await refreshMessageCount()
    }
}
