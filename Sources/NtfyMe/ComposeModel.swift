import Foundation
import Observation
import NtfyKit

/// A destination handed to the Compose window before it opens — "send to
/// this topic" from the History window's toolbar or a row's context menu.
///
/// Only the destination, deliberately: the message fields stay empty, since
/// pre-filling a draft with someone else's words invites sending text the
/// user did not write.
struct ComposeSeed: Equatable, Sendable {
    let serverID: UUID
    let topic: String
}

/// Backs the Compose window: the draft, the destination, and one send.
///
/// Shaped like `SettingsModel` deliberately — `@MainActor @Observable`, with
/// its collaborators injected as closures rather than reached for — so the
/// whole thing is testable with no AppKit, no window, and no network. The
/// one error channel (`errorMessage`) is the same pattern and exists for the
/// same reason: spec §10 forbids a silent failure, and a send is the one
/// action in this app whose failure the user must not have to guess at.
@MainActor
@Observable
final class ComposeModel {
    private let store: MessageStore
    private let keychain: KeychainStore
    /// Injected rather than a `NtfyPublisher` held directly, so a test can
    /// drive every branch below — each error case, and the state left behind
    /// after success — without a server to publish to.
    private let publish: @Sendable (MessageDraft, URL, AuthCredential) async throws -> Void

    /// What the window's fields bind to.
    var draft = MessageDraft()
    /// The destination server. Separate from `draft` because it is not part
    /// of the message — see `MessageDraft`'s doc comment.
    var selectedServerID: UUID?
    /// Tags as one comma-separated field, which is how ntfy's own CLI takes
    /// them (`--tags warning,skull`) and how they arrive on the wire.
    /// Parsed into `draft.tags` on every edit so the draft is always the
    /// thing that gets sent, never a stale parse of this string.
    var tagText: String = "" {
        didSet {
            guard oldValue != tagText else { return }
            draft.tags = Self.parseTags(tagText)
        }
    }

    private(set) var servers: [ServerRecordSnapshot] = []
    private(set) var topics: [TopicSummary] = []
    private(set) var isSending = false
    /// Set after a successful send and cleared when the next one starts —
    /// the window's only positive feedback, since a published message
    /// otherwise arrives silently (or, if the topic is subscribed, as a
    /// notification a second later, which is not the same as the window
    /// saying it worked).
    private(set) var lastSentSummary: String?
    var errorMessage: String?

    init(store: MessageStore, keychain: KeychainStore,
         publish: @escaping @Sendable (MessageDraft, URL, AuthCredential) async throws -> Void) {
        self.store = store
        self.keychain = keychain
        self.publish = publish
    }

    /// The subscribed topics on the selected server, offered as suggestions
    /// for the topic field. Suggestions, not a constraint: publishing does
    /// not require a subscription, and limiting the field to subscriptions
    /// would invent a rule ntfy does not have.
    var topicSuggestions: [String] {
        guard let selectedServerID else { return [] }
        return topics.filter { $0.serverID == selectedServerID }.map(\.topic)
    }

    var canSend: Bool {
        // `topicValidation == .valid`, not just `draft.isSendable`'s non-empty
        // check: an invalid topic is a request that can only fail at the
        // server, and the destination bar already shows why — disabling the
        // button is the same answer given before the round trip instead of
        // after it.
        selectedServerID != nil && draft.isSendable
            && topicValidation == .valid && !isSending
    }

    /// The destination bar's trailing mark, straight from ntfy's own rule
    /// (`NtfyEndpoint.isTopicValid`) rather than a second copy of it. Empty
    /// is its own state — nothing typed yet is not an error, and painting a
    /// warning on a fresh window would be scolding the user for arriving.
    var topicValidation: TopicValidation {
        if draft.topic.isEmpty { return .empty }
        return NtfyEndpoint.isTopicValid(draft.topic) ? .valid : .invalid
    }

    enum TopicValidation: Equatable {
        case empty, valid, invalid
    }

    /// Applies a destination handed over before the window opened (see
    /// `ComposeSeed`). Runs before `refresh()`, whose keep-or-repair logic
    /// then does the right thing for free: a server that still exists keeps
    /// the selection, and a non-empty topic is never overwritten by the
    /// single-topic prefill.
    func prefill(from seed: ComposeSeed) {
        selectedServerID = seed.serverID
        draft.topic = seed.topic
    }

    func refresh() async {
        do {
            servers = try await store.servers()
            topics = try await store.topicSummaries()
        } catch {
            let ns = error as NSError
            Log.app.error("compose refresh failed: \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
            errorMessage = "Couldn't load your servers."
            return
        }

        // Keep a selection the user already made unless it has gone away.
        if selectedServerID == nil || !servers.contains(where: { $0.id == selectedServerID }) {
            selectedServerID = servers.first?.id
        }
        // Prefilled only when there is exactly one subscribed topic on the
        // selected server, where it cannot be the wrong guess. With several,
        // the field stays empty: this button sends a message to whatever is
        // in it, and a plausible-looking prefilled destination is the wrong
        // kind of convenience for that.
        if draft.topic.isEmpty, topicSuggestions.count == 1 {
            draft.topic = topicSuggestions[0]
        }
    }

    func send() async {
        guard !isSending, draft.isSendable, let serverID = selectedServerID else { return }
        guard let server = servers.first(where: { $0.id == serverID }) else {
            errorMessage = "That server is no longer configured."
            return
        }

        isSending = true
        defer { isSending = false }
        errorMessage = nil
        lastSentSummary = nil

        let credential: AuthCredential
        do {
            credential = try keychain.load(forServer: serverID)
        } catch {
            // The same call this app's connections make, handled the same
            // way — see `ConnectionCoordinator.open`: a credential that
            // cannot be read is not a reason to refuse to try, because an
            // unauthenticated attempt gets a 401 the user can see, and that
            // is more useful than a refusal they cannot act on.
            Log.app.error("keychain read failed for server \(serverID.uuidString, privacy: .public)")
            credential = .unauthenticated
        }

        // Captured before the send: on success the draft is cleared, and
        // the confirmation must name where the message actually went.
        let destination = draft.topic
        do {
            try await publish(draft, server.baseURL, credential)
        } catch let error as NtfyPublisher.Error {
            errorMessage = Self.message(for: error)
            return
        } catch let error as NtfyEndpoint.Error {
            errorMessage = Self.message(for: error)
            return
        } catch {
            // Offline, DNS, TLS. `domain`/`code` only, never
            // `localizedDescription` — a `URLError`'s description embeds the
            // URL, and a server's hostname is sensitive (spec §9).
            let ns = error as NSError
            Log.app.error("publish transport failure: \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
            errorMessage = "Couldn't reach the server."
            return
        }

        lastSentSummary = "Sent to \(destination)"
        // Server, topic and priority survive; the message does not. Sending
        // several messages to one topic is the common case, and re-picking
        // the destination every time is friction for no reason — but leaving
        // the body sitting there invites sending it twice.
        draft.title = nil
        draft.body = ""
        tagText = ""
        draft.tags = []
    }

    /// Splits the tag field. Trimmed, empties dropped, order kept — so
    /// "warning, , skull" is two tags rather than three, one of which the
    /// server would reject.
    static func parseTags(_ text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Every publish failure as a sentence, in one place. No server-supplied
    /// text and no URL ever reaches these — see `NtfyPublisher.Error`.
    static func message(for error: NtfyPublisher.Error) -> String {
        switch error {
        case .notAuthorized:
            "Not authorized to publish to this topic. Check this server's credential in Settings."
        case .topicRejected:
            "The server rejected that topic."
        case .tooLarge:
            "That message is too large for this server."
        case .rateLimited:
            "The server is rate-limiting right now. Try again shortly."
        case .unexpectedStatus(let code):
            "The server refused the message (HTTP \(code))."
        case .notAnHTTPResponse:
            "The server's reply wasn't HTTP."
        }
    }

    static func message(for error: NtfyEndpoint.Error) -> String {
        switch error {
        case .invalidTopic:
            // Deliberately does not echo the topic back: it is the one thing
            // on this window the user can already see.
            "That topic name isn't valid. Use letters, numbers, dashes or underscores, up to 64 characters."
        case .invalidServerURL:
            "That server's address can't be used to publish."
        case .noTopics:
            // Not reachable from a publish, which always has exactly one
            // topic — `send()` guards on `draft.isSendable` first.
            "No topic."
        }
    }
}
