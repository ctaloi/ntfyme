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
