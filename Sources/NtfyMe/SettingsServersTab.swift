import SwiftUI
import NtfyKit

/// Spec §7: "add, edit, remove; credential entry; a test-connection button."
///
/// **Edit is credential-only.** `MessageStore` has no method to update a
/// server's name or base URL after `addServer` — only `addServer` and
/// `removeServer` exist. Renaming or re-pointing a server would need
/// deleting and recreating the row, which would also delete its message
/// history (`removeServer`'s doc comment: it purges history explicitly,
/// because messages are keyed by `serverID`, not cascaded from `Server`).
/// That trade is not worth making silently, so this tab only lets a
/// credential be rotated in place; name and address are shown read-only with
/// an explanation. See the wave2-settings report for the `MessageStore` API
/// this needs to support full editing.
struct SettingsServersTab: View {
    let model: SettingsModel

    @State private var isPresentingAddServer = false
    @State private var editingServer: ServerRecordSnapshot?
    @State private var pendingRemoval: ServerRecordSnapshot?

    var body: some View {
        VStack(spacing: 0) {
            if model.servers.isEmpty {
                ContentUnavailableView {
                    Label("No Servers", systemImage: "server.rack")
                } description: {
                    Text("Add a server to start following topics.")
                }
            } else {
                List {
                    ForEach(model.servers) { server in
                        ServerRow(
                            server: server,
                            topics: model.topics(for: server.id),
                            onEdit: { editingServer = server },
                            onRemove: { pendingRemoval = server },
                            onAddTopic: { topic in
                                Task { await model.addTopic(topic, toServer: server.id) }
                            },
                            onRemoveTopic: { topic in
                                Task { await model.removeTopic(topic, fromServer: server.id) }
                            },
                            onSetAlertSettings: { topic, settings in
                                Task { await model.setAlertSettings(settings, serverID: server.id, topic: topic) }
                            }
                        )
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                Button {
                    isPresentingAddServer = true
                } label: {
                    Label("Add Server\u{2026}", systemImage: "plus")
                }
                .accessibilityLabel("Add Server")

                Spacer()

                if model.isLoadingServers {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(12)
        }
        .sheet(isPresented: $isPresentingAddServer) {
            SettingsServerEditor(model: model, mode: .add, onDismiss: { isPresentingAddServer = false })
        }
        .sheet(item: $editingServer) { server in
            SettingsServerEditor(model: model, mode: .editCredential(server), onDismiss: { editingServer = nil })
        }
        .confirmationDialog(
            "Remove \(pendingRemoval?.name ?? "this server")?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { isPresented in if !isPresented { pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Server and Message History", role: .destructive) {
                if let server = pendingRemoval {
                    Task { await model.removeServer(server.id) }
                }
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("This deletes the server, its saved credential, and every message stored for it. This cannot be undone.")
        }
    }
}

/// One server's row: identity, credential kind, and its topics — each with a
/// mute toggle, a minimum-alert-priority stepper, and a remove button — plus
/// an inline field to add another topic.
private struct ServerRow: View {
    let server: ServerRecordSnapshot
    let topics: [TopicSummary]
    let onEdit: () -> Void
    let onRemove: () -> Void
    let onAddTopic: (String) -> Void
    let onRemoveTopic: (String) -> Void
    let onSetAlertSettings: (String, TopicAlertSettings) -> Void

    @State private var newTopic = ""

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(topics) { topic in
                    topicRow(topic)
                }

                HStack {
                    TextField("New topic name", text: $newTopic)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(submitTopic)
                        .accessibilityLabel("New topic name")
                    Button("Add", action: submitTopic)
                        .disabled(newTopic.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                // Spec §9: a topic name is effectively a password on public
                // ntfy.sh. Stated here, at the point a topic is actually
                // added, not only in the onboarding pane or a help page.
                Text("On public ntfy.sh, anyone who knows a topic's name can read and publish to it \u{2014} treat it like a password.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name).font(.headline)
                    Text(server.baseURL.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text((SettingsCredentialKind(rawValue: server.authKindRaw) ?? .unauthenticated).displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Edit\u{2026}", action: onEdit)
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Edit credential for \(server.name)")

                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove server \(server.name)")
            }
        }
    }

    private func topicRow(_ topic: TopicSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(topic.topic)
                Spacer()
                Toggle("Muted", isOn: Binding(
                    get: { topic.muted },
                    set: { onSetAlertSettings(topic.topic, TopicAlertSettings(muted: $0, minAlertPriority: topic.minAlertPriority)) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel("Mute topic \(topic.topic)")

                Button(role: .destructive) {
                    onRemoveTopic(topic.topic)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove topic \(topic.topic)")
            }
            Stepper(
                value: Binding(
                    get: { topic.minAlertPriority },
                    set: { onSetAlertSettings(topic.topic, TopicAlertSettings(muted: topic.muted, minAlertPriority: $0)) }
                ),
                in: 1...5
            ) {
                Text("Minimum alert priority: \(topic.minAlertPriority)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func submitTopic() {
        let trimmed = newTopic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onAddTopic(trimmed)
        newTopic = ""
    }
}

/// Add-server sheet, or credential-only editor for an existing one — see
/// `SettingsServersTab`'s doc comment for why edit is credential-only.
struct SettingsServerEditor: View {
    enum Mode {
        case add
        case editCredential(ServerRecordSnapshot)
    }

    let model: SettingsModel
    let mode: Mode
    let onDismiss: () -> Void

    @State private var name = ""
    @State private var baseURLString = ""
    @State private var kind: SettingsCredentialKind = .unauthenticated
    @State private var token = ""
    @State private var username = ""
    @State private var password = ""
    @State private var validationError: String?
    @State private var isSaving = false
    @State private var testResult: String?
    @State private var isTesting = false

    var body: some View {
        Form {
            switch mode {
            case .add:
                Section {
                    TextField("Name", text: $name)
                        .accessibilityLabel("Server name")
                    TextField("https://ntfy.example.com", text: $baseURLString)
                        .accessibilityLabel("Server address")
                } header: {
                    Text("Server")
                } footer: {
                    // Spec §9, stated at the point a server is configured,
                    // ahead of the first topic this server will carry.
                    Text("On public ntfy.sh, a topic name works like a password \u{2014} anyone who knows it can read and publish to it.")
                }

            case .editCredential(let server):
                Section {
                    LabeledContent("Name", value: server.name)
                    LabeledContent("Address", value: server.baseURL.absoluteString)
                } header: {
                    Text("Server")
                } footer: {
                    Text("Renaming a server or changing its address isn't supported yet \u{2014} remove and re-add the server to change either.")
                }
            }

            Section("Credential") {
                Picker("Type", selection: $kind) {
                    ForEach(SettingsCredentialKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .accessibilityLabel("Credential type")

                switch kind {
                case .unauthenticated:
                    EmptyView()
                case .bearer:
                    SecureField("Token", text: $token)
                        .accessibilityLabel("Bearer token")
                case .basic:
                    TextField("Username", text: $username)
                        .accessibilityLabel("Username")
                    SecureField("Password", text: $password)
                        .accessibilityLabel("Password")
                }
            }

            if let validationError {
                Text(validationError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Section {
                Button {
                    Task { await runConnectionTest() }
                } label: {
                    Label(isTesting ? "Testing\u{2026}" : "Test Connection", systemImage: "network")
                }
                .disabled(isTesting)

                if let testResult {
                    Text(testResult)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 440)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onDismiss)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isSaving ? "Saving\u{2026}" : "Save") {
                    Task { await save() }
                }
                .disabled(isSaving)
            }
        }
        .onAppear(perform: prefill)
    }

    private func prefill() {
        switch mode {
        case .add:
            break
        case .editCredential(let server):
            kind = SettingsCredentialKind(rawValue: server.authKindRaw) ?? .unauthenticated
        }
    }

    private func resolvedBaseURL() -> URL? {
        switch mode {
        case .add: try? SettingsServerValidation.validatedBaseURL(baseURLString)
        case .editCredential(let server): server.baseURL
        }
    }

    private func runConnectionTest() async {
        validationError = nil
        testResult = nil
        guard let url = resolvedBaseURL() else {
            validationError = "Enter a valid server address first."
            return
        }
        let credential: AuthCredential
        do {
            credential = try SettingsCredentialBuilder.makeCredential(
                kind: kind, token: token, username: username, password: password)
        } catch {
            validationError = error.localizedDescription
            return
        }

        isTesting = true
        defer { isTesting = false }
        switch await model.testConnection(baseURL: url, credential: credential) {
        case .reachable:
            testResult = "Reachable."
        case .unauthorized:
            testResult = "Reachable, but the credential was rejected."
        case .unexpectedStatus(let code):
            testResult = "Server responded with status \(code)."
        case .failed(let message):
            testResult = "Couldn't reach the server: \(message)"
        }
    }

    private func save() async {
        validationError = nil
        let credential: AuthCredential
        do {
            credential = try SettingsCredentialBuilder.makeCredential(
                kind: kind, token: token, username: username, password: password)
        } catch {
            validationError = error.localizedDescription
            return
        }

        isSaving = true
        defer { isSaving = false }

        switch mode {
        case .add:
            let validatedName: String
            let validatedURL: URL
            do {
                validatedName = try SettingsServerValidation.validatedName(name)
                validatedURL = try SettingsServerValidation.validatedBaseURL(baseURLString)
            } catch {
                validationError = error.localizedDescription
                return
            }
            if await model.addServer(name: validatedName, baseURL: validatedURL, kind: kind, credential: credential) {
                onDismiss()
            }

        case .editCredential(let server):
            if await model.updateCredential(serverID: server.id, credential: credential) {
                onDismiss()
            }
        }
    }
}
