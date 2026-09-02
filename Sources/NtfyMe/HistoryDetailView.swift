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
                Text(snapshot.topic)
                Text("·")
                Text(snapshot.time, format: .dateTime.year().month().day().hour().minute())
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
            return Text(attributed)
        } catch {
            return Text(snapshot.body)
        }
    }

    private var tagRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(snapshot.tags, id: \.self) { TagChip(tag: $0) }
            }
        }
    }

    /// Resolves the attachment's local file for Quick Look. `MessageSnapshot`
    /// carries no attachment metadata today: `Attachment` is a SwiftData
    /// relationship that never crosses `MessageStore`'s actor boundary as a
    /// value, and nothing in this codebase calls `AttachmentDownloader` yet.
    /// This always returns `nil` until a future `MessageSnapshot` grows an
    /// attachment filename and this view is handed the attachments
    /// directory to resolve it against — see this branch's report for the
    /// follow-up this needs.
    private var localAttachmentURL: URL? { nil }

    /// Only `view` and `copy` action kinds are offered here. `http` actions
    /// need the same header-and-method allow-list `NotificationDecision`
    /// applies to notification action buttons, and that logic is `private`
    /// to `NtfyKit` — duplicating attacker-facing sanitization in a second
    /// place risks the two drifting apart. Omitting the button is the safe
    /// default until that logic is exposed for reuse.
    private var messageActions: [PresentableAction] {
        snapshot.actions.prefix(3).compactMap { action in
            switch action.kind {
            case .view:
                guard let raw = action.url, let url = URL(string: raw),
                      let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
                else { return nil }
                return PresentableAction(id: action.id, title: action.label, kind: .view(url: url))
            case .copy:
                guard let value = action.value else { return nil }
                // Same 1024 UTF-8 byte cap `NotificationDecision` applies to
                // a copy action's value, measured the same way — in UTF-8
                // bytes, not `String.count`, so a base character plus many
                // combining marks cannot smuggle far more data onto the
                // clipboard than the cap intends.
                let capped = String(decoding: Array(value.utf8.prefix(1024)), as: UTF8.self)
                return PresentableAction(id: action.id, title: action.label, kind: .copy(value: capped))
            case .http, .broadcast, nil:
                return nil
            }
        }
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
