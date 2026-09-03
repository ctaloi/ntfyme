import Foundation

/// A `Sendable` view of one `Attachment`.
///
/// Deliberately omits the remote URL (`Attachment.urlString`): the UI has no
/// business fetching it directly. `AttachmentDownloader` owns that, with its
/// scheme allow-list, size cap, and credential-stripped session — leaving
/// the URL off this snapshot makes that safe path the only path available
/// to a caller that only has a `MessageSnapshot`.
public struct AttachmentSnapshot: Sendable, Equatable {
    public let name: String
    public let type: String?
    public let size: Int?
    /// Set only once the file has actually been downloaded. `nil` means
    /// metadata exists but no local file does — the UI must not attempt a
    /// Quick Look preview (or anything else that reads a local file) when
    /// this is `nil`.
    public let localFilename: String?

    public init(name: String, type: String?, size: Int?, localFilename: String?) {
        self.name = name
        self.type = type
        self.size = size
        self.localFilename = localFilename
    }
}

/// A `Sendable` view of one `Message`.
///
/// `@Model` classes are not `Sendable` and must never cross an actor boundary
/// under Swift 6 strict concurrency. Every value the store hands out is one of
/// these instead.
public struct MessageSnapshot: Sendable, Equatable, Identifiable {
    public let id: String            // the uniqueKey
    public let messageID: String
    public let topic: String
    public let serverID: UUID
    public let time: Date
    public let title: String?
    public let body: String
    public let priority: Int
    public let tags: [String]
    public let click: String?
    public let iconURL: String?
    public let contentType: String?
    public let actionsJSON: Data?
    /// Decoded once, when the snapshot is built — not a computed property
    /// re-decoding on every access. Empty means "no actions", full stop: a
    /// decode failure is handled at construction (`Message.snapshot`), logged
    /// there, and never reaches here silently disguised as the same `[]`.
    public let actions: [NtfyAction]
    /// The one settable field on this otherwise immutable snapshot. Every
    /// other field is a fact about the stored message; this one is a fact
    /// about its reader, and it is the only one a surface changes while
    /// holding a loaded row.
    ///
    /// Settable so `HistoryViewModel.markRead` can update the rows it has
    /// rather than re-running its query: a message read *inside* the
    /// "Unread" view has to stay on screen while it is being read, and a
    /// re-query is exactly what removed it (the query no longer matches it).
    /// Marking a row read is not the same event as the list's contents
    /// changing, and this is what lets them be told apart.
    public var isRead: Bool
    public let attachment: AttachmentSnapshot?

    public var isMarkdown: Bool { contentType == "text/markdown" }

    /// The body as a plain-text preview, for a surface that shows a line or
    /// two of it rather than the whole message: the History list rows and
    /// the menu bar popover.
    ///
    /// Those showed `body` verbatim, so a markdown message previewed as its
    /// own source — "`/var` is at 96% on **db-01**." backticks, asterisks
    /// and all — while the detail pane beside it rendered the same message
    /// properly. Found by looking at a render, not reported.
    ///
    /// `.inlineOnlyPreservingWhitespace` is the right interpretation for a
    /// preview specifically: inline markup (emphasis, code spans, links) is
    /// consumed and its markers removed, while block structure is left as
    /// the plain text it already looks like. The full block-aware treatment
    /// is `HistoryDetailView.bodyText`'s job, and it needs 40 lines of run
    /// walking to put the paragraph breaks back — none of which a
    /// two-line preview would show.
    ///
    /// Falls back to the raw body if the markdown will not parse, matching
    /// `HistoryDetailView`: an ntfy message body is arbitrary remote input
    /// (spec §9), so a publisher sending broken markdown must get plain
    /// text rather than nothing.
    public var previewText: String {
        guard isMarkdown else { return body }
        guard let attributed = try? AttributedString(
            markdown: body,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace))
        else { return body }
        return String(attributed.characters)
    }
    public var resolvedPriority: NtfyPriority { NtfyPriority(rawValue: priority) ?? .default }
}

extension Message {
    public var snapshot: MessageSnapshot {
        let actions: [NtfyAction]
        if let actionsJSON {
            do {
                actions = try JSONDecoder().decode([NtfyAction].self, from: actionsJSON)
            } catch {
                // A stored blob this app wrote itself; a decode failure means
                // the row is corrupt rather than "no actions were attached" —
                // those two cases must not collapse into the same silent `[]`.
                // The error itself is never logged: `DecodingError`'s
                // description quotes the offending data, which can carry an
                // action's `url`, `label`, or `body` — exactly the message
                // content spec §9 forbids in logs (see Log.swift).
                Log.store.error(
                    "failed to decode stored actions for message on server \(self.serverID.uuidString, privacy: .public)"
                )
                actions = []
            }
        } else {
            actions = []
        }

        let attachmentSnapshot = attachment.map {
            AttachmentSnapshot(name: $0.name, type: $0.type, size: $0.size,
                              localFilename: $0.localFilename)
        }

        return MessageSnapshot(id: uniqueKey, messageID: messageID, topic: topic,
                        serverID: serverID, time: time, title: title, body: body,
                        priority: priority, tags: tags, click: click,
                        iconURL: iconURL, contentType: contentType,
                        actionsJSON: actionsJSON, actions: actions, isRead: isRead,
                        attachment: attachmentSnapshot)
    }
}
