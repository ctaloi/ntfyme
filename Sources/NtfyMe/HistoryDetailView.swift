import AppKit
import QuickLook
import SwiftUI
import NtfyKit

/// The detail column: the single selected message, a summary when several
/// rows are selected, or an empty-state placeholder when none are.
struct HistoryDetailView: View {
    @Bindable var viewModel: HistoryViewModel

    var body: some View {
        Group {
            let selected = viewModel.messages.filter { viewModel.selection.contains($0.id) }
            if selected.isEmpty {
                HistoryStatusView(systemImage: "envelope", title: "No Message Selected",
                                  message: "Select a message to see its contents.")
            } else if selected.count == 1 {
                MessageDetailContent(snapshot: selected[0], viewModel: viewModel)
            } else {
                MultiSelectionSummary(snapshots: selected, viewModel: viewModel)
            }
        }
        // `maxWidth`/`maxHeight: .infinity` matter here, not just `minWidth`:
        // the empty-selection and multi-selection branches are small,
        // centered content that does not itself ask for the full column —
        // without forcing the `Group` to fill the column before the
        // background below is applied, that background only paints behind
        // the small centered block and leaves the rest of the column
        // transparent. Found via `meanAlpha` on `history-no-selection.png`
        // measuring 0.64 against a 0.85 floor — a second unpainted region,
        // same bug class as the one below, in the branch that background
        // fix did not actually reach.
        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        // `NavigationSplitView`'s detail column normally gets its background
        // from the window automatically — but every color used below
        // (`.primary`, `.secondary`, the priority/tag colors) is dynamic and
        // resolves to a *light* value under `.dark`, same as the menu bar
        // popover's fix (`MenuBarPopoverView.swift`). Without this, dark
        // mode is light text over whatever backing happens to be there,
        // which in this app's offscreen snapshot tests was nothing at all:
        // confirmed by `history-populated-dark.png` rendering the entire
        // detail column invisible before this line existed.
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct MessageDetailContent: View {
    let snapshot: MessageSnapshot
    let viewModel: HistoryViewModel
    @State private var quickLookURL: URL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                Divider()
                bodyText
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                if !snapshot.tags.isEmpty {
                    tagRow
                }
                if let attachmentURL = localAttachmentURL {
                    Button {
                        quickLookURL = attachmentURL
                    } label: {
                        Label("Preview Attachment", systemImage: "eye")
                    }
                }
                if !messageActions.isEmpty {
                    actionButtons
                }
                Spacer(minLength: 0)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .quickLookPreview($quickLookURL)
        .toolbar { toolbarActions }
        .navigationTitle(snapshot.title?.isEmpty == false ? snapshot.title! : snapshot.topic)
        // `AttributedString(markdown:)` can produce a clickable link from
        // the message body with an arbitrary scheme — a path that looks
        // like ordinary framework behavior rather than attacker-controlled
        // input, but the body is exactly that (spec §9). Intercepting
        // `openURL` here routes every link tap in this view, markdown or
        // not, through the same `NtfyURLPolicy` the click/action buttons use,
        // instead of SwiftUI's default handler opening it unchecked.
        .environment(\.openURL, OpenURLAction { url in
            guard let sanitized = NtfyURLPolicy.sanitized(url.absoluteString) else { return .discarded }
            NSWorkspace.shared.open(sanitized)
            return .handled
        })
    }

    /// 22pt title, one metadata line (topic · server · time, with the
    /// priority marker trailing it), matching the redesign mockup —
    /// replacing the old two-line header where the title's own row also
    /// carried a `PriorityPill` at the trailing edge.
    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            iconImage
            titleAndMetadata
        }
    }

    /// ntfy's `icon` field: a URL to an image the publisher wants shown with
    /// the message. It has been decoded (`NtfyEvent.icon`), persisted
    /// (`Models.swift`) and carried into `MessageSnapshot.iconURL` since the
    /// first version of this app, and displayed nowhere — this is the first
    /// place it is drawn.
    ///
    /// Through `NtfyURLPolicy.sanitized`, like every other URL that arrives
    /// in a message: an icon URL is attacker-controlled (spec §9), and this
    /// is the app's one scheme allow-list.
    ///
    /// Two known limits, both deliberate:
    ///
    /// - Loading it is a read receipt. Fetching a remote image tells whoever
    ///   published the message that this message was opened, exactly like a
    ///   tracking pixel in an email. It loads anyway — every ntfy client
    ///   does, and the user chose to subscribe to the topic — but it loads
    ///   *here*, in the detail pane, and not in the list row: a row-level
    ///   icon would fetch for all 200 loaded messages, turning "the one I
    ///   opened" into "every message that scrolled past".
    /// - `AsyncImage` does not bound the download. A publisher can point
    ///   `icon` at an arbitrarily large file. Capping it needs a
    ///   `URLSession` of our own with a size limit rather than `AsyncImage`,
    ///   which is more than this display fix; recorded in `followups.md`.
    @ViewBuilder
    private var iconImage: some View {
        if let url = NtfyURLPolicy.sanitized(snapshot.iconURL) {
            AsyncImage(url: url) { phase in
                // Only the success case draws. No spinner and no broken-image
                // placeholder: an icon is decoration, and a message whose
                // publisher pointed `icon` at a 404 should look like a
                // message with no icon, not like a message that failed.
                if let image = phase.image {
                    image.resizable().aspectRatio(contentMode: .fit)
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            // The title beside it already says everything this conveys.
            .accessibilityHidden(true)
        }
    }

    private var titleAndMetadata: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(snapshot.title?.isEmpty == false ? snapshot.title! : snapshot.topic)
                .font(.system(size: 22, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                // A long topic name must stay one line and truncate — the
                // same rule the sidebar already applies to long topic names
                // — rather than wrap: a wrapped topic pushes the rest of
                // this metadata line down to sit stranded beside the
                // wrapped block instead of reading as one line.
                Text(snapshot.topic)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("·").foregroundStyle(.tertiary)
                Text(serverName)
                Text("·").foregroundStyle(.tertiary)
                Text(snapshot.time, format: .dateTime.year().month().day().hour().minute())
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 8)
                if snapshot.priority >= NtfyPriority.high.rawValue {
                    Image(systemName: "exclamationmark.2")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(snapshot.priority >= NtfyPriority.max.rawValue ? .red : .orange)
                        .accessibilityLabel(Text("Priority: \(snapshot.resolvedPriority.label)"))
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }

    private var serverName: String {
        viewModel.servers.first(where: { $0.id == snapshot.serverID })?.name ?? "Unknown Server"
    }

    /// `AttributedString(markdown:)` throws on malformed input. An ntfy
    /// message body is arbitrary remote input (spec §9), so a publisher that
    /// sends broken markdown must fall back to plain text, never crash the
    /// window or render nothing.
    private var bodyText: Text {
        guard snapshot.isMarkdown else { return Text(snapshot.body) }
        do {
            let attributed = try AttributedString(
                markdown: snapshot.body,
                options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full))
            return Text(Self.separatingBlocks(attributed))
        } catch {
            return Text(snapshot.body)
        }
    }

    /// `Text(AttributedString)` renders inline styling (bold, links, code
    /// spans) correctly, but never inserts anything between separate
    /// block-level elements — two markdown paragraphs, or two list items,
    /// render run together with no space or line break at all, because
    /// `AttributedString` only records that structure as `presentationIntent`
    /// metadata, which `Text` does not consult on its own (confirmed
    /// visually: a headless snapshot of this exact view showed
    /// "...for full logs.Exit code: 137Duration: 4m12s" as one unbroken run).
    /// Walking the runs and inserting a newline wherever the enclosing block
    /// changes — compared by the *whole* intent chain, not just its `Kind`,
    /// since two consecutive paragraphs both have kind `.paragraph` but never
    /// share an `identity` — is what actually separates them. A list item
    /// also gets its marker restored here (`listPrefix(for:)`): without it, a
    /// markdown list renders as unmarked plain lines indistinguishable from
    /// prose, which loses real structure for exactly the kind of alert body
    /// (exit codes, durations, checklists) ntfy messages tend to use lists
    /// for.
    private static func separatingBlocks(_ attributed: AttributedString) -> AttributedString {
        var result = AttributedString()
        var previousBlock: PresentationIntent?
        for run in attributed.runs {
            let block = run.presentationIntent
            if block != previousBlock {
                if previousBlock != nil {
                    result += AttributedString("\n")
                }
                if let prefix = listPrefix(for: block) {
                    result += AttributedString(prefix)
                }
            }
            result += attributed[run.range]
            previousBlock = block
        }
        return result
    }

    /// `nil` unless `block`'s intent chain includes a `.listItem` — a list
    /// item's own text carries no bullet or number of its own, only this
    /// metadata. Ordered vs. unordered is read off the chain too (a
    /// `.listItem` is always paired with an enclosing `.orderedList` or
    /// `.unorderedList` component), not guessed from the ordinal alone.
    private static func listPrefix(for block: PresentationIntent?) -> String? {
        guard let components = block?.components,
              let listItem = components.first(where: {
                  if case .listItem = $0.kind { return true }
                  return false
              }),
              case .listItem(let ordinal) = listItem.kind
        else { return nil }
        let isOrdered = components.contains {
            if case .orderedList = $0.kind { return true }
            return false
        }
        return isOrdered ? "\(ordinal). " : "• "
    }

    /// Emoji tags as emoji, then the rest as chips.
    ///
    /// The reported bug: every tag rendered as a text chip, so a message
    /// published with ntfy's documented `--tags warning,telephone_receiver`
    /// arrived looking like it carried two stray labels rather than ⚠️ 📞.
    ///
    /// Unlike the list row and the banner, the emoji are not folded into the
    /// title here — the detail pane has the room to show them at a size
    /// where they read as pictures, and the tag row is where a reader
    /// already looks for a message's tags.
    private var tagRow: some View {
        let tags = NtfyEmoji.split(tags: snapshot.tags)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                if !tags.emoji.isEmpty {
                    // No `accessibilityLabel`: VoiceOver names an emoji
                    // ("warning sign") better than a label built from the
                    // short code would ("Tag: warning").
                    Text(tags.emoji.joined(separator: " "))
                        .font(.system(size: 20))
                }
                ForEach(tags.labels, id: \.self) { TagChip(tag: $0) }
            }
        }
        .fadedTrailingEdge()
    }

    /// Resolves the attachment's local file for Quick Look, or `nil` when
    /// there is nothing to preview: no attachment, no downloaded file yet
    /// (`localFilename == nil`), or no attachments directory configured
    /// (`HistoryWindowController` was constructed without one).
    ///
    /// The path-component guard mirrors `MessageStore.prune`'s: `localFilename`
    /// is generated by `AttachmentDownloader` today and should already be a
    /// bare component, but a Quick Look preview reading a path this view
    /// builds from server-influenced metadata should not depend on every
    /// future writer of that field getting it right.
    private var localAttachmentURL: URL? {
        guard let filename = snapshot.attachment?.localFilename,
              !filename.isEmpty, !filename.contains("/"), !filename.contains("\\"),
              filename != ".", filename != "..",
              let directory = viewModel.attachmentsDirectory
        else { return nil }
        return directory.appendingPathComponent(filename)
    }

    /// The sanitized, presentable subset of `snapshot.actions` — delegates to
    /// `NotificationDecision.presentableActions`, the one place the
    /// URL-scheme allow-list, HTTP method allow-list, and header deny-list
    /// for a message's action buttons are expressed (spec §9: a message is
    /// attacker-controlled). Reusing it, now that it is public, is what
    /// makes `http` actions safe to offer here too.
    private var messageActions: [PresentableAction] {
        NotificationDecision.presentableActions(from: snapshot.actions)
    }

    private var actionButtons: some View {
        HStack {
            ForEach(messageActions) { action in
                Button(action.title) {
                    Task { await NotificationActionHandler.perform(action) }
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarActions: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                Task { await viewModel.markRead([snapshot], read: !snapshot.isRead) }
            } label: {
                Label(snapshot.isRead ? "Mark as Unread" : "Mark as Read",
                      systemImage: snapshot.isRead ? "envelope.badge" : "envelope.open")
            }
            .help(snapshot.isRead ? "Mark as Unread" : "Mark as Read")

            Button {
                viewModel.copy([snapshot])
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .help("Copy")

            if snapshot.click != nil {
                Button {
                    viewModel.openClickURL(snapshot)
                } label: {
                    Label("Open Link", systemImage: "arrow.up.right.square")
                }
                .help("Open Link")
            }

            Button(role: .destructive) {
                Task { await viewModel.delete([snapshot]) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .help("Delete")
        }
    }
}

private struct MultiSelectionSummary: View {
    let snapshots: [MessageSnapshot]
    let viewModel: HistoryViewModel

    var body: some View {
        VStack(spacing: 16) {
            Text("\(snapshots.count) Messages Selected")
                .font(.title3.bold())
            HStack {
                Button("Mark as Read") { Task { await viewModel.markRead(snapshots, read: true) } }
                Button("Mark as Unread") { Task { await viewModel.markRead(snapshots, read: false) } }
                Button("Copy") { viewModel.copy(snapshots) }
                Button("Delete", role: .destructive) { Task { await viewModel.delete(snapshots) } }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
