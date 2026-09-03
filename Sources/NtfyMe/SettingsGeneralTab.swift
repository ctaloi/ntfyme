import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers
import NtfyKit

/// Spec §7: "launch at login (`SMAppService.mainApp`), retention window,
/// badge behavior" — plus, since the Advanced tab was folded in here,
/// "export history to JSON, clear data."
///
/// **Why Advanced's export/clear moved here rather than staying a fourth
/// tab.** With the log-level control removed (see `SettingsAdvancedTab`'s
/// former doc comment — that type no longer exists), Advanced held exactly
/// one group, titled "History" — the same title as this tab's retention
/// group. Two tabs with a "History" heading, one holding limits and the
/// other holding export/clear, is exactly the kind of split that makes
/// people hunt for a setting they can see is somewhere. A tab holding one
/// thin group was not earning its place in the tab bar, so its content
/// joins this section instead of getting a new, different heading to stay
/// distinguishable — one "History" section, holding everything about the
/// archive, is the simpler shape.
///
/// **No `Form` here.** See `SettingsSection`'s doc comment for why: neither
/// `Form` style read as part of the same application as the native-first
/// redesign. Plain `VStack`s at this file's own type scale instead.
struct SettingsGeneralTab: View {
    let model: SettingsModel

    /// Menu-bar unread badging is not modeled anywhere the wiring pass
    /// already has a home for it — `Preferences` carries no such field — so
    /// it lives in plain `UserDefaults` under this app's own key, read
    /// directly by whichever view ends up drawing the badge. Flagged in the
    /// wave2-settings report as a knob this tab persists but does not yet
    /// wire to real behavior.
    @AppStorage("settings.general.badgeMenuBarIcon") private var badgeEnabled = true

    @State private var retentionDaysText = ""
    @State private var maxPerTopicText = ""
    @State private var isExporting = false
    @State private var isClearing = false
    @State private var isPresentingClearConfirm = false
    @State private var exportStatus: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                SettingsSection(title: "Startup") {
                    Toggle("Launch NtfyMe at login", isOn: launchAtLoginBinding)
                        .font(.system(size: 13))
                        .accessibilityHint(Text("Registers NtfyMe as a login item using Service Management."))

                    if model.loginItemStatus == .requiresApproval {
                        Label(
                            "Needs approval in System Settings \u{2192} General \u{2192} Login Items.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                    }
                }

                SettingsSection(title: "History") {
                    SettingsRow(label: "Keep messages for") {
                        HStack(spacing: 6) {
                            TextField("", text: $retentionDaysText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 52)
                                .multilineTextAlignment(.trailing)
                                .onSubmit(applyRetention)
                                .accessibilityLabel("Retention window, in days")
                            Text("days")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                    }
                    SettingsRow(label: "Keep up to") {
                        HStack(spacing: 6) {
                            TextField("", text: $maxPerTopicText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 68)
                                .multilineTextAlignment(.trailing)
                                .onSubmit(applyRetention)
                                .accessibilityLabel("Maximum stored messages per topic")
                            Text("messages per topic")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                    }
                    SettingsFootnote("Whichever limit is reached first applies. Changes take effect on the next retention pass.")

                    Divider()
                        .padding(.vertical, 4)

                    SettingsRow(label: "Stored messages") {
                        Text("\(model.messageCount)")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 10) {
                        Button {
                            Task { await exportHistory() }
                        } label: {
                            Label(isExporting ? "Exporting\u{2026}" : "Export History to JSON\u{2026}", systemImage: "square.and.arrow.up")
                        }
                        .disabled(isExporting || model.messageCount == 0)

                        Button(role: .destructive) {
                            isPresentingClearConfirm = true
                        } label: {
                            Label(isClearing ? "Clearing\u{2026}" : "Clear All Message History\u{2026}", systemImage: "trash")
                        }
                        .disabled(isClearing || model.messageCount == 0)
                    }
                    .controlSize(.regular)

                    if let exportStatus {
                        SettingsFootnote(exportStatus)
                    }
                }

                SettingsSection(title: "Menu Bar") {
                    Toggle("Badge the menu bar icon with the unread count", isOn: $badgeEnabled)
                        .font(.system(size: 13))
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: syncRetentionFields)
        .onChange(of: model.prefs.retention) { _, _ in syncRetentionFields() }
        .confirmationDialog(
            "Clear all message history?",
            isPresented: $isPresentingClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) {
                Task { await clearHistory() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes every stored message on every server. Servers and their saved credentials are kept. This cannot be undone.")
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { model.prefs.launchAtLogin },
            set: { model.setLaunchAtLogin($0) }
        )
    }

    private func syncRetentionFields() {
        retentionDaysText = String(Int(model.prefs.retention.maxAge / 86_400))
        maxPerTopicText = String(model.prefs.retention.maxMessagesPerTopic)
    }

    private func applyRetention() {
        guard let days = Int(retentionDaysText), let maxPerTopic = Int(maxPerTopicText) else {
            model.errorMessage = "Enter whole numbers for retention."
            syncRetentionFields()
            return
        }
        model.setRetention(days: days, maxMessagesPerTopic: maxPerTopic)
    }

    /// Fetches the whole archive off the main thread's blocking path
    /// (`model.fetchAllMessages()` runs on `MessageStore`'s own actor), then
    /// encodes it in a detached task rather than inline here —
    /// `[MessageSnapshot]` is `Sendable`, so handing it to
    /// `Task.detached` is safe, and it is exactly the step spec §7 warns
    /// must not block the main thread for a large archive. Only after both
    /// finish does this touch AppKit, on the main actor, for the save panel.
    private func exportHistory() async {
        isExporting = true
        exportStatus = nil
        defer { isExporting = false }

        let snapshots: [MessageSnapshot]
        do {
            snapshots = try await model.fetchAllMessages()
        } catch {
            exportStatus = "Export failed while reading history."
            return
        }

        let data: Data
        do {
            data = try await Task.detached(priority: .utility) {
                try SettingsHistoryExport.encode(snapshots)
            }.value
        } catch {
            exportStatus = "Export failed while encoding JSON."
            return
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "NtfyMe-history.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try data.write(to: url, options: .atomic)
            exportStatus = "Exported \(snapshots.count) message\(snapshots.count == 1 ? "" : "s")."
        } catch {
            // Never interpolates `error` or `url`: a file-write failure's
            // description embeds the destination path, which is a
            // user-chosen filesystem location outside anything Log.swift's
            // carve-outs cover. The panel already told the user where they
            // asked to save; this just reports that it didn't work.
            exportStatus = "Couldn't write the export file."
        }
    }

    private func clearHistory() async {
        isClearing = true
        defer { isClearing = false }
        await model.clearAllMessages()
    }
}
