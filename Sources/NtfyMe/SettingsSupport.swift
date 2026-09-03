import Foundation
import NtfyKit

// MARK: - Shared UserDefaults keys
//
// One definition per key, so the Notifications tab's `@AppStorage` and
// `SettingsModel`'s plain `UserDefaults` reads of the same value cannot
// drift apart into two different strings.
enum SettingsDefaultsKey {
    /// The minimum alert priority a newly added topic is seeded with
    /// (`SettingsModel.addTopic`). Read with `UserDefaults.integer(forKey:)`
    /// rather than through `@AppStorage`, so the fallback for an absent key
    /// must be applied explicitly — see `SettingsModel.defaultMinAlertPriority`.
    static let defaultMinPriority = "settings.notifications.defaultMinPriority"

    /// Gates the `ntfy.sh` default-server seed (`SettingsModel
    /// .seedDefaultServerIfNeeded`) to a genuine first run. Deliberately not
    /// derived from "the server list is empty": a user who deletes the
    /// seeded server must see it stay deleted, not have it reappear because
    /// the list emptied out again. Set only once the seed attempt actually
    /// succeeds, so a transient failure on one launch is retried on the next
    /// rather than being recorded as done.
    static let hasSeededDefaultServer = "settings.hasSeededDefaultServer"
}

// MARK: - Credential kind
//
// Everything below this line down to `SettingsHistoryExport` is deliberately
// framework-free — no SwiftUI, no actor, no I/O — so it can be exercised by a
// plain unit test the moment a test target exists for this module. See the
// wave2-settings report for the `Package.swift` stanza and the exact type
// names a follow-up test target should cover.

/// The three credential shapes a server can have, independent of whatever is
/// currently sitting in the Keychain. Mirrors `AuthCredential`'s cases and
/// `KeychainStore`'s own `Stored.kind` strings exactly, so a value round-trips
/// through `MessageStore.addServer(authKindRaw:)` and the Keychain without
/// translation at any call site.
enum SettingsCredentialKind: String, CaseIterable, Identifiable, Equatable, Sendable {
    case unauthenticated
    case bearer
    case basic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .unauthenticated: "None"
        case .bearer: "Bearer Token"
        case .basic: "Username & Password"
        }
    }

    static func kind(of credential: AuthCredential) -> SettingsCredentialKind {
        switch credential {
        case .unauthenticated: .unauthenticated
        case .bearer: .bearer
        case .basic: .basic
        }
    }
}

/// A reason a Settings form was rejected before it ever reached the store or
/// the Keychain. `description` is shown to the user as-is — plain, specific
/// text rather than a closed enum, because every call site already knows
/// exactly which case it is producing.
struct SettingsValidationError: LocalizedError, Equatable, Sendable {
    let description: String
    var errorDescription: String? { description }
}

enum SettingsCredentialBuilder {
    /// Builds the credential a form's raw text fields describe, or throws a
    /// user-facing reason it cannot. Never silently downgrades to
    /// `.unauthenticated` for a kind the user actually chose bearer/basic
    /// for with empty fields — that would save a server the user meant to
    /// secure with no credential at all.
    static func makeCredential(kind: SettingsCredentialKind, token: String,
                               username: String, password: String) throws -> AuthCredential {
        switch kind {
        case .unauthenticated:
            return .unauthenticated
        case .bearer:
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw SettingsValidationError(description: "Enter a bearer token.")
            }
            return .bearer(token: trimmed)
        case .basic:
            let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !user.isEmpty else {
                throw SettingsValidationError(description: "Enter a username.")
            }
            guard !password.isEmpty else {
                throw SettingsValidationError(description: "Enter a password.")
            }
            return .basic(user: user, password: password)
        }
    }
}

// MARK: - Server form validation

enum SettingsServerValidation {
    /// A trimmed, non-empty name, or a reason it is rejected.
    static func validatedName(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SettingsValidationError(description: "Enter a name for this server.")
        }
        return trimmed
    }

    /// An `http`/`https` URL with a host, or a reason it is rejected.
    /// Anything else — a bare word, a `file://` path, a scheme-less string
    /// `URL` happily parses — is rejected here rather than left to fail
    /// obscurely the first time a connection attempt runs.
    static func validatedBaseURL(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else {
            throw SettingsValidationError(description: "Enter a valid http:// or https:// server address.")
        }
        return url
    }
}

// MARK: - Retention validation

enum SettingsRetentionValidation {
    /// Turns raw form values into a `RetentionPolicy`, or a reason to reject
    /// them. `PreferencesStore.load()` already treats a stored zero as
    /// corrupt and silently substitutes the default (see its doc comment) —
    /// this validator is what keeps a zero from ever being written in the
    /// first place.
    static func validate(days: Int, maxMessagesPerTopic: Int) throws -> RetentionPolicy {
        guard days >= 1 else {
            throw SettingsValidationError(description: "Retention must be at least 1 day.")
        }
        guard maxMessagesPerTopic >= 1 else {
            throw SettingsValidationError(description: "Keep at least 1 message per topic.")
        }
        return RetentionPolicy(maxAge: TimeInterval(days) * 86_400,
                               maxMessagesPerTopic: maxMessagesPerTopic)
    }
}

// MARK: - Notification authorization

/// This app's own mirror of the three `UNAuthorizationStatus` cases a user
/// can actually act on (`.provisional`/`.ephemeral` collapse into
/// `.authorized` — notifications still show either way, and this app never
/// requests them itself). Kept as a local enum, not `UNAuthorizationStatus`
/// directly, so `SettingsNotificationsTab.swift` never has to import
/// `UserNotifications` — the mapping happens once, in
/// `NotificationPresenter` via the wiring pass, the one place this app
/// already talks to `UNUserNotificationCenter`.
enum SettingsNotificationAuthorization: Equatable, Sendable {
    case authorized
    case denied
    case notDetermined
}

// MARK: - JSON export

/// A dependency-free mirror of `MessageSnapshot` shaped for JSON export.
/// Deliberately excludes `actionsJSON` — the raw stored blob, a redundant,
/// less-readable encoding of the same `actions` this already carries — and
/// carries nothing that was not already in the archive the user asked to
/// export. No credential and no server hostname beyond `serverID`, a UUID
/// this app generated locally: the export never touches the Keychain and
/// never reads a `Server` row's `baseURLString`.
struct SettingsExportedMessage: Codable, Equatable, Sendable {
    let serverID: UUID
    let topic: String
    let messageID: String
    let time: Date
    let title: String?
    let body: String
    let priority: Int
    let tags: [String]
    let click: String?
    let iconURL: String?
    let contentType: String?
    let actions: [NtfyAction]
    let isRead: Bool

    init(_ snapshot: MessageSnapshot) {
        serverID = snapshot.serverID
        topic = snapshot.topic
        messageID = snapshot.messageID
        time = snapshot.time
        title = snapshot.title
        body = snapshot.body
        priority = snapshot.priority
        tags = snapshot.tags
        click = snapshot.click
        iconURL = snapshot.iconURL
        contentType = snapshot.contentType
        actions = snapshot.actions
        isRead = snapshot.isRead
    }
}

enum SettingsHistoryExport {
    /// Pure and synchronous. The Advanced tab's export action — the caller
    /// that actually cares about not blocking the main thread on a large
    /// archive — runs this inside `Task.detached` itself; this function does
    /// not hop actors on its own, so it stays trivially testable.
    static func encode(_ snapshots: [MessageSnapshot]) throws -> Data {
        let exportable = snapshots.map(SettingsExportedMessage.init)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(exportable)
    }
}

// MARK: - Subscription import/export

/// One subscription as it travels through an export/import file: everything
/// needed to re-subscribe on another machine, and pointedly nothing else —
/// **credentials never appear here**. A bearer token is the Keychain's
/// business and the receiving machine's to ask for; an export file that
/// could carry one would be a password spreadsheet waiting to be emailed.
/// Server address, topic, and the alert settings a new subscription would
/// otherwise lose.
struct SubscriptionTransfer: Codable, Sendable, Equatable, Identifiable {
    /// The server's base URL, as a string. Normalized on import (host
    /// lowercased, trailing slash dropped) so a file written on a machine
    /// that typed `HTTPS://ntfy.sh/` still matches the server this machine
    /// already has.
    var server: String
    var topic: String
    var displayName: String?
    var muted: Bool
    var minAlertPriority: Int

    var id: String { "\(server)/\(topic)" }
}

/// The file format. `version` exists so a future format change can be
/// detected by field rather than by decoder crash.
struct SubscriptionTransferFile: Codable {
    var version: Int
    var subscriptions: [SubscriptionTransfer]
}

enum SubscriptionsTransferCodec {
    static let version = 1

    static func encode(_ subscriptions: [SubscriptionTransfer]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(
            SubscriptionTransferFile(version: version, subscriptions: subscriptions))
    }

    /// Decodes and validates. Every field the importer acts on is checked
    /// here — a file is arbitrary input from disk (the same posture every
    /// network message gets): an unknown version, a missing topic, a
    /// non-numeric priority outside 1...5, or an unparseable server URL
    /// each rejects the whole file rather than half-importing it.
    static func decode(_ data: Data) throws -> [SubscriptionTransfer] {
        let file = try JSONDecoder().decode(SubscriptionTransferFile.self, from: data)
        guard file.version == version else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: [],
                debugDescription: "Unsupported subscriptions file version \(file.version)."))
        }
        var seen = Set<String>()
        var result: [SubscriptionTransfer] = []
        for var transfer in file.subscriptions {
            let topic = transfer.topic.trimmingCharacters(in: .whitespacesAndNewlines)
            guard NtfyEndpoint.isTopicValid(topic) else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: [],
                    debugDescription: "The file contains an invalid topic name."))
            }
            guard let url = normalizedServerURL(transfer.server) else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: [],
                    debugDescription: "The file contains a server address that isn't usable."))
            }
            guard (1...5).contains(transfer.minAlertPriority) else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: [],
                    debugDescription: "The file contains an out-of-range alert priority."))
            }
            transfer.topic = topic
            transfer.server = url.absoluteString
            // A file with the same subscription twice would import the
            // second copy as a skip; the dedup here is for the *picker*, so
            // the user never sees the same row twice.
            guard seen.insert(transfer.id).inserted else { continue }
            result.append(transfer)
        }
        return result
    }

    /// Host lowercased, trailing slash dropped — the same shape two
    /// machines' independently-typed copies of one server URL normalize
    /// to. Returns `nil` for anything without an http(s) host. The scheme
    /// is lowercased before parsing: `URLComponents` treats an uppercase
    /// scheme (`HTTPS://…`, which a human absolutely will type) as
    /// host-less and the whole URL would otherwise be refused.
    static func normalizedServerURL(_ string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let schemeEnd = trimmed.range(of: "://") else { return nil }
        let canonicalized = trimmed[..<schemeEnd.lowerBound].lowercased()
            + trimmed[schemeEnd.lowerBound...]
        guard var components = URLComponents(string: canonicalized),
              let host = components.host, !host.isEmpty,
              components.scheme == "http" || components.scheme == "https"
        else { return nil }
        components.host = host.lowercased()
        // A bare "/" is the root path, not a meaningful trailing slash —
        // strip it to nothing so `https://host/` and `https://host` are the
        // same server for matching purposes.
        components.path = components.path == "/" ? "" : (components.path as NSString).removingTrailingSlash()
        return components.url
    }
}

extension NSString {
    fileprivate func removingTrailingSlash() -> String {
        if length > 1 && character(at: length - 1) == UnicodeScalar("/").value {
            return substring(to: length - 1)
        }
        return self as String
    }
}
