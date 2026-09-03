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
                // `Form(.formStyle(.grouped))` paints its own ground on
                // every other tab; this is the one state in Settings that
                // isn't a `Form`, so without this it paints none at all —
                // fine today only because the window behind it happens to
                // be the same colour, the same shape of thing as the three
                // "forgot to paint a ground" bugs this wave's snapshot
                // review caught elsewhere. Matches explicitly rather than
                // relying on that coincidence.
                ContentUnavailableView {
                    Label("No Servers", systemImage: "server.rack")
                } description: {
                    Text("Add a server to start following topics.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .settingsBackground()
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
        // `List` paints its own ground; the footer bar below it (`Divider`
        // plus the `Add Server` `HStack`) is plain content sitting outside
        // the `List` in this same `VStack`, so without this it painted
        // none of its own — invisible in dark-mode captures once the
        // window grew tall enough to leave visible space below the rows,
        // the same "forgot to paint a ground" shape already fixed twice
        // elsewhere in this file.
        .settingsBackground()
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
///
/// **A plain disclosure, not `DisclosureGroup`.** Two problems traced to it:
/// its automatic indicator was clipped at the row's leading edge (visible as
/// a stray sliver next to the server name), and — going back to this wave's
/// very first snapshot review — its `isExpanded` state never visibly took
/// effect in a headless capture no matter what was tried (an extra
/// layout/display pass, disabling its implicit animation, ordering the
/// window front). That capture gap was real but harmless as long as nobody
/// could tell the difference between "collapsed in the screenshot" and
/// "collapsed for real" — until a review read the always-collapsed
/// screenshots as the topics being gone from the tab. A plain `Button`
/// toggling `isExpanded` plus an `if isExpanded` block owns its own chevron
/// (no clipping) and its own conditional content (no dependency on
/// `DisclosureGroup`'s internal animation machinery), so both the row and
/// what a screenshot of it shows are correct.
private struct ServerRow: View {
    let server: ServerRecordSnapshot
    let topics: [TopicSummary]
    let onEdit: () -> Void
    let onRemove: () -> Void
    let onAddTopic: (String) -> Void
    let onRemoveTopic: (String) -> Void
    let onSetAlertSettings: (String, TopicAlertSettings) -> Void

    @State private var newTopic = ""
    // Expanded by default: a server's topics are this row's actual content,
    // and with only a handful of servers ever configured there is little
    // reason to make every one of them a click to see.
    @State private var isExpanded = true

    private var credentialKind: SettingsCredentialKind {
        SettingsCredentialKind(rawValue: server.authKindRaw) ?? .unauthenticated
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12, height: 20)
                        .accessibilityHidden(true)

                    // Auth kind moved off the trailing edge and onto this
                    // metadata line, dot-separated after the address —
                    // matching the main window's own row convention
                    // ("alerts · Home Lab · Today at 7:45 PM") — because at
                    // this window's width a trailing-aligned label ended up
                    // roughly a thousand pixels from the name it described.
                    VStack(alignment: .leading, spacing: 3) {
                        Text(server.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                        HStack(spacing: 5) {
                            Text(server.baseURL.absoluteString)
                            Text("\u{00b7}").foregroundStyle(.tertiary)
                            Text(credentialKind.displayName)
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Edit\u{2026}", action: onEdit)
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Edit credential for \(server.name)")

                    Button(role: .destructive, action: onRemove) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove server \(server.name)")
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(server.name), \(isExpanded ? "expanded" : "collapsed")")
            .accessibilityAddTraits(.isButton)

            if isExpanded {
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

                    // Spec §9: a topic name is effectively a password on
                    // public ntfy.sh. Stated here, at the point a topic is
                    // actually added, not only in the onboarding pane or a
                    // help page.
                    Text("On public ntfy.sh, anyone who knows a topic's name can read and publish to it \u{2014} treat it like a password.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 20)
                .padding(.bottom, 10)
            }
        }
    }

    private func topicRow(_ topic: TopicSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(topic.topic)
                    .font(.system(size: 13))
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
                    .font(.system(size: 12))
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
        VStack(spacing: 0) {
            // Deliberately outside the `Form` for `.editCredential`, not a
            // `Section` of `LabeledContent` rows: `.formStyle(.grouped)`
            // gives a read-only row the exact same rounded-rect background
            // as an editable one, so "Name"/"Address" rows here used to
            // look exactly like the editable rows elsewhere in Settings — a
            // user had to try clicking into one to learn otherwise, which
            // is the opposite of what the sentence below already says. A
            // plain header above the form, matching how `ServerRow` already
            // presents a server's identity in the list this sheet was
            // opened from, reads as this sheet's title rather than a field.
            if case .editCredential(let server) = mode {
                VStack(alignment: .leading, spacing: 4) {
                    Text(server.name)
                        .font(.system(size: 17, weight: .semibold))
                    Text(server.baseURL.absoluteString)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("Renaming a server or changing its address isn't supported yet \u{2014} remove and re-add the server to change either.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
                .accessibilityElement(children: .combine)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top])
                Divider()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if case .add = mode {
                        SettingsSection(title: "Server") {
                            TextField("Name", text: $name)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("Server name")
                            TextField("https://ntfy.example.com", text: $baseURLString)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("Server address")
                            // Spec §9, stated at the point a server is
                            // configured, ahead of the first topic this
                            // server will carry.
                            SettingsFootnote("On public ntfy.sh, a topic name works like a password \u{2014} anyone who knows it can read and publish to it.")
                        }
                    }

                    SettingsSection(title: "Credential") {
                        Picker("Type", selection: $kind) {
                            ForEach(SettingsCredentialKind.allCases) { kind in
                                Text(kind.displayName).tag(kind)
                            }
                        }
                        .pickerStyle(.menu)
                        .accessibilityLabel("Credential type")

                        switch kind {
                        case .unauthenticated:
                            EmptyView()
                        case .bearer:
                            SecureField("Token", text: $token)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("Bearer token")
                        case .basic:
                            TextField("Username", text: $username)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("Username")
                            SecureField("Password", text: $password)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("Password")
                        }
                    }

                    if let validationError {
                        Text(validationError)
                            .font(.system(size: 12))
                            .foregroundStyle(.red)
                    }

                    SettingsSection(title: "Connection") {
                        Button {
                            Task { await runConnectionTest() }
                        } label: {
                            Label(isTesting ? "Testing\u{2026}" : "Test Connection", systemImage: "network")
                        }
                        .disabled(isTesting)

                        if let testResult {
                            SettingsFootnote(testResult)
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 460, height: 480)
        // The header added for `.editCredential` sits outside the `Form`,
        // which paints its own ground, so without this explicit background
        // that header area painted none of its own — the same "forgot to
        // paint a ground" shape this wave's snapshot review already caught
        // twice elsewhere (`meanAlpha` is what caught it here too).
        .settingsBackground()
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
