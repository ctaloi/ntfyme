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
        .frame(minWidth: 320)
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
            VStack(alignment: .leading, spacing: 16) {
                header
                bodyText
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(snapshot.title?.isEmpty == false ? snapshot.title! : snapshot.topic)
                    .font(.title2.bold())
                Spacer()
                PriorityPill(priority: snapshot.resolvedPriority)
            }
            HStack(spacing: 6) {
                // A long topic name must stay one line and truncate — the
                // same rule the sidebar already applies to long topic names
                // — rather than wrap: a wrapped topic pushes the "· time"
                // that follows it down to sit stranded beside the wrapped
                // block instead of reading as one metadata line.
                Text(snapshot.topic)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("·")
                Text(snapshot.time, format: .dateTime.year().month().day().hour().minute())
                    .fixedSize(horizontal: true, vertical: false)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
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

    private var tagRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(snapshot.tags, id: \.self) { TagChip(tag: $0) }
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
