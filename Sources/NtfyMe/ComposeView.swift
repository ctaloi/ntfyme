import SwiftUI
import NtfyKit

/// The Compose window: pick a destination, write a message, send it.
///
/// Reuses `SettingsSection`/`SettingsRow`/`SettingsFootnote` and
/// `.settingsBackground()` from `SettingsComponents.swift`. Their names say
/// Settings, but what they are is this app's plain left-aligned layout
/// rhythm — the alternative was a second set of identical pieces under a
/// different name, and two layout vocabularies in one app is how surfaces
/// start looking like they came from different applications.
struct ComposeView: View {
    /// One width for every labelled control, so their trailing edges line
    /// up in a column instead of each ending wherever its own intrinsic
    /// width happens to fall. `SettingsRow` pushes its content right with a
    /// `Spacer`, so equal widths are all it takes — the first render of this
    /// window had the server picker ending 115pt short of the tag field,
    /// which reads as carelessness even when nothing is functionally wrong.
    ///
    /// A fixed width rather than `maxWidth`: a `Picker` given `maxWidth`
    /// takes its own smaller ideal width and leaves the rest of the frame
    /// empty, which is exactly how the edges came to disagree.
    ///
    /// The pickers additionally need `alignment: .trailing`, because a
    /// `Picker` does not stretch to fill a fixed frame either — it centres
    /// its intrinsic width inside it, which left both popup buttons ending
    /// ~150pt short of the text fields in the second render. A popup button
    /// narrower than a text field is normal on macOS; one that stops in a
    /// different place from every other control is not.
    private static let controlWidth: CGFloat = 260

    @Bindable var model: ComposeModel
    /// Called when a send succeeds and the window should get out of the way.
    /// Injected rather than reaching for the window: this view has no
    /// business knowing it lives in one (and the snapshot tests render it
    /// without one).
    var onSent: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            destination
            message
            Spacer(minLength: 0)
            footer
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 480)
        .settingsBackground()
        .task { await model.refresh() }
    }

    private var destination: some View {
        SettingsSection(title: "Send to") {
            SettingsRow(label: "Server") {
                Picker("", selection: $model.selectedServerID) {
                    // A `nil` tag is required, not decorative: `Picker`
                    // renders an empty selection box with no matching tag,
                    // which reads as a broken control rather than as
                    // "nothing chosen yet".
                    Text("Choose…").tag(UUID?.none)
                    ForEach(model.servers) { server in
                        Text(server.name).tag(UUID?.some(server.id))
                    }
                }
                .labelsHidden()
                .frame(width: Self.controlWidth, alignment: .trailing)
            }

            SettingsRow(label: "Topic") {
                HStack(spacing: 6) {
                    TextField("topic-name", text: $model.draft.topic)
                        .textFieldStyle(.roundedBorder)
                    // Subscribed topics as suggestions. Absent entirely
                    // when there are none, rather than an empty menu the
                    // user can open and learn nothing from.
                    if !model.topicSuggestions.isEmpty {
                        Menu {
                            ForEach(model.topicSuggestions, id: \.self) { topic in
                                Button(topic) { model.draft.topic = topic }
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        // `.borderlessButton` draws its own disclosure
                        // chevron, so the `Image` above made two of them
                        // side by side — visible in the first render of
                        // this window.
                        .menuIndicator(.hidden)
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .accessibilityLabel(Text("Choose a subscribed topic"))
                    }
                }
                .frame(width: Self.controlWidth)
            }

            SettingsFootnote("Any topic, not only the ones you subscribe to. On ntfy.sh a topic name is effectively a password.")
        }
    }

    private var message: some View {
        SettingsSection(title: "Message") {
            TextField("Title (optional)", text: Binding(
                // `draft.title` is `String?` — empty is the same as absent
                // for this field, and `NtfyEndpoint.publishRequest` omits
                // both from the body.
                get: { model.draft.title ?? "" },
                set: { model.draft.title = $0.isEmpty ? nil : $0 }))
                .textFieldStyle(.roundedBorder)

            TextEditor(text: $model.draft.body)
                .font(.system(size: 13))
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.3)))
                .accessibilityLabel(Text("Message body"))

            SettingsRow(label: "Priority") {
                Picker("", selection: $model.draft.priority) {
                    ForEach(NtfyPriority.allCases, id: \.self) { priority in
                        Text(priority.label).tag(priority)
                    }
                }
                .labelsHidden()
                .frame(width: Self.controlWidth, alignment: .trailing)
            }

            SettingsRow(label: "Tags") {
                TextField("warning, skull", text: $model.tagText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: Self.controlWidth)
            }

            // Emoji tags are the same convention the receive side renders
            // (see `NtfyEmoji`), so say so here rather than leaving the user
            // to discover that some tags become pictures.
            SettingsFootnote("Comma-separated. A tag naming an emoji — warning, rocket, skull — is shown as that emoji.")
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let errorMessage = model.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let sent = model.lastSentSummary {
                Label(sent, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.green)
            }

            HStack {
                Spacer()
                if model.isSending {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(Text("Sending"))
                }
                Button("Send") {
                    Task {
                        await model.send()
                        if model.errorMessage == nil { onSent() }
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canSend)
            }
        }
    }
}
