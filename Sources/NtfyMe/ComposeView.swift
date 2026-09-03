import AppKit
import SwiftUI
import NtfyKit

/// The Compose window: pick a destination, write a message, send it.
///
/// The first version of this window was a Settings form — label-left,
/// control-right rows reusing `SettingsRow`, which was honest about what it
/// was and read like a preferences pane for it. A compose surface is not a
/// preference; it is a document the user fills in and fires. So it now has
/// its own layout, built around three ideas:
///
/// - **The destination is a sentence, not two dropdowns.** One bar reads
///   `server › topic` the way the URL it will become reads, with ntfy's own
///   topic rule (`NtfyEndpoint.isTopicValid`) checking the topic live — a
///   green check the moment it is sendable, an amber warning the moment it
///   is not, instead of an HTTP 400 teaching the same lesson after a round
///   trip.
/// - **What you see is what arrives.** A preview card below the fields
///   renders the message the way it will arrive — emoji tags already
///   turned into pictures, title falling back to the topic, body
///   truncated the way a banner truncates — so the emoji-tag convention
///   ("warning" becomes ⚠️) is something the user *watches happen* while
///   typing, not something the docs knew and they didn't.
/// - **The feedback is at the bottom, the button is at the bottom, and
///   they are the same glance apart.** Errors sit directly above Send, in
///   a sentence that names the fix.
///
/// The window still binds to `ComposeModel` exactly as before — `draft`,
/// `tagText`, `send()` — so every model test carries over unchanged.
struct ComposeView: View {
    @Bindable var model: ComposeModel
    /// Called when a send succeeds and the window should get out of the way.
    /// Injected rather than reaching for the window: this view has no
    /// business knowing it lives in one (and the snapshot tests render it
    /// without one).
    var onSent: () -> Void = {}

    /// Rings the message card when either of its two fields has focus —
    /// the same affordance a focused text field gets, applied to the card
    /// that stands in for one.
    @FocusState private var messageFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            destination
            messageCard
            controls
            preview
            Spacer(minLength: 0)
            footer
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 620)
        .settingsBackground()
        .task { await model.refresh() }
    }

    // MARK: - Destination

    /// One bar: server › topic, reading left to right exactly as the URL
    /// it becomes will. The trailing mark is the live topic check.
    private var destination: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "server.rack")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                serverMenu

                Text("›")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)

                TextField("topic-name", text: $model.draft.topic)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium).monospaced())
                    .accessibilityLabel(Text("Topic"))

                Spacer(minLength: 4)

                // Three states, no fourth: nothing while the field is empty
                // (an untouched field is not an error), a green check when
                // ntfy would take it, amber when it would not.
                switch model.topicValidation {
                case .empty:
                    EmptyView()
                case .valid:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityLabel(Text("Topic name is valid"))
                case .invalid:
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityLabel(Text("Topic name is not valid"))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .animation(.snappy(duration: 0.2), value: model.topicValidation)

            // Subscribed topics as one-tap chips — offered while the field
            // is empty, gone the moment it is not. A `Menu` of suggestions
            // (the first version) hid them behind a chevron worth less than
            // the space it took; chips put the destinations on the table.
            // One line each, in a horizontal scroll: a chip that wraps its
            // own text becomes a pill two rows tall, which is exactly the
            // "weird" this row shipped as once a real topic name
            // ("homelab-alerts") met it.
            if model.draft.topic.isEmpty, !model.topicSuggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Text("Yours:")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                        ForEach(Array(model.topicSuggestions.prefix(6).enumerated()), id: \.offset) { _, topic in
                            Button(topic) {
                                model.draft.topic = topic
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium).monospaced())
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                            .foregroundStyle(Color.accentColor)
                        }
                    }
                    .textSelection(.disabled)
                }
            }

            SettingsFootnote("Any topic, not only the ones you subscribe to. On ntfy.sh a topic name is effectively a password.")
        }
    }

    private var serverMenu: some View {
        Menu {
            ForEach(model.servers) { server in
                Button {
                    model.selectedServerID = server.id
                } label: {
                    Label(server.name, systemImage:
                            server.id == model.selectedServerID
                          ? "checkmark" : "server.rack")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selectedServerName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        // `.borderlessButton` draws its own disclosure chevron; the one in
        // the label above is the only one, exactly as the topic field's old
        // suggestion menu learned the hard way.
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Text("Server"))
    }

    private var selectedServerName: String {
        guard let id = model.selectedServerID,
              let server = model.servers.first(where: { $0.id == id })
        else { return "Choose…" }
        return server.name
    }

    // MARK: - Message

    /// Title and body as one document — the way the message will read on
    /// the other end — rather than two separately-stroked fields floating
    /// in a form. The card takes a focus ring when either field is in it,
    /// which is the standard "this is the thing I'm editing" signal.
    private var messageCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Title", text: Binding(
                // `draft.title` is `String?` — empty is the same as absent
                // for this field, and `NtfyEndpoint.publishRequest` omits
                // both from the body.
                get: { model.draft.title ?? "" },
                set: { model.draft.title = $0.isEmpty ? nil : $0 }))
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .semibold))
                .focused($messageFocused)
                .accessibilityLabel(Text("Title"))
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)

            Divider()
                .padding(.leading, 12)

            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.draft.body)
                    .font(.system(size: 13))
                    .focused($messageFocused)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 110)
                    .accessibilityLabel(Text("Message body"))
                if model.draft.body.isEmpty {
                    Text("Message — markdown renders for readers.")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 8)
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(messageFocused ? Color.accentColor.opacity(0.45)
                          : Color.secondary.opacity(0.18), lineWidth: 1))
        .animation(.snappy(duration: 0.15), value: messageFocused)
    }

    // MARK: - Priority and tags

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Priority")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Picker("", selection: $model.draft.priority) {
                    ForEach(NtfyPriority.allCases, id: \.self) { priority in
                        Text(priority.label).tag(priority)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 300)

                // A bell that keeps pace with the picker: the same icon the
                // notification will effectively be delivered with. Bounces
                // on change, which is exactly as serious as this indicator
                // deserves to be.
                Image(systemName: prioritySymbol)
                    .foregroundStyle(priorityTint)
                    .symbolEffect(.bounce, value: model.draft.priority)
                    .accessibilityLabel(Text("Priority: \(model.draft.priority.label)"))
            }

            HStack(spacing: 10) {
                Text("Tags")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                TextField("warning, rocket", text: $model.tagText)
                    .textFieldStyle(.roundedBorder)
                // The fun part, live: type "warning, rocket" and watch it
                // become ⚠️ 🚀 while you type. Same table the receive side
                // renders, so what appears here is what arrives.
                if !tagEmoji.isEmpty {
                    Text(tagEmoji.joined(separator: " "))
                        .font(.system(size: 15))
                        .transition(.opacity)
                        .accessibilityLabel(Text("These tags render as emoji"))
                }
            }

            if !tagChips.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(tagChips, id: \.self) { TagChip(tag: $0) }
                    }
                }
                .fadedTrailingEdge()
            }
        }
        .animation(.snappy(duration: 0.2), value: tagEmoji)
    }

    private var parsedTags: [String] { ComposeModel.parseTags(model.tagText) }

    private var tagEmoji: [String] { NtfyEmoji.split(tags: parsedTags).emoji }

    private var tagChips: [String] { NtfyEmoji.split(tags: parsedTags).labels }

    private var priorityTint: Color {
        switch model.draft.priority {
        case .min, .low, .default: .secondary
        case .high: .orange
        case .max: .red
        }
    }

    private var prioritySymbol: String {
        switch model.draft.priority {
        case .min: "bell.slash"
        case .low, .default: "bell"
        case .high: "bell.fill"
        case .max: "bell.ring.fill"
        }
    }

    // MARK: - Preview

    /// The message as it will arrive — a small replica of a macOS banner,
    /// fed by the same `NtfyEmoji` table the list row and the notification
    /// use, so the three cannot disagree. Updates live as the user types,
    /// which is the whole point: the preview is the emoji convention made
    /// visible, not a decorative frame.
    private var preview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Delivers as")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)

            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(LinearGradient(
                            colors: [Color.accentColor, Color.accentColor.opacity(0.7)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "bell.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                }
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(previewTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(previewBody)
                        .font(.system(size: 12))
                        .foregroundStyle(model.draft.body.isEmpty ? .tertiary : .secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Text("now")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Preview: \(previewTitle). \(model.draft.body.isEmpty ? "No message yet" : previewBody)"))
    }

    private var previewTitle: String {
        NtfyEmoji.prefixed(titleForPreview, tags: parsedTags)
    }

    private var titleForPreview: String {
        if let title = model.draft.title, !title.isEmpty { return title }
        if !model.draft.topic.isEmpty { return model.draft.topic }
        return "Untitled message"
    }

    private var previewBody: String {
        let body = model.draft.body
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? "Your message text will appear here." : body
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Animated in and out, since the two states swap places rather
            // than coexist and a hard cut between them reads as a flicker.
            Group {
                if let errorMessage = model.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else if let sent = model.lastSentSummary {
                    Label(sent, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .font(.system(size: 12))
            .fixedSize(horizontal: false, vertical: true)
            .animation(.snappy(duration: 0.2), value: model.errorMessage)
            .animation(.snappy(duration: 0.2), value: model.lastSentSummary)

            HStack {
                // The one-line answer to "what happens when I press this":
                // name the destination, so the last thing the user reads
                // before sending is where it is going.
                if let id = model.selectedServerID,
                   let server = model.servers.first(where: { $0.id == id }),
                   !model.draft.topic.isEmpty {
                    Text("Publishes to \(server.name) › \(model.draft.topic)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if model.isSending {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(Text("Sending"))
                }
                Button(action: send) {
                    Label("Send", systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canSend)
            }
        }
    }

    /// Sends, and on success gets out of the way — with a sound, because the
    /// window is gone before any banner the user could read appears. A send
    /// is fast; the one confirmation that always reaches the user is audio.
    private func send() {
        Task {
            await model.send()
            if model.errorMessage == nil {
                NSSound(named: "Pop")?.play()
                onSent()
            }
        }
    }
}
