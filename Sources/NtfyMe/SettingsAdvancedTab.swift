import SwiftUI
import AppKit
import UniformTypeIdentifiers
import NtfyKit

/// Spec §7: "export history to JSON, clear data, log level."
///
/// **No log-level control.** `Log.swift` defines four fixed `os.Logger`
/// categories with no runtime verbosity knob, and adding one is new
/// `NtfyKit` surface with no test coverage — decided against at the merge
/// gate, the same call as "play a sound" in the Notifications tab. Can come
/// back with its own plumbing and tests later.
struct SettingsAdvancedTab: View {
    let model: SettingsModel

    @State private var isExporting = false
    @State private var isClearing = false
    @State private var isPresentingClearConfirm = false
    @State private var exportStatus: String?

    var body: some View {
        Form {
            Section("History") {
                LabeledContent("Stored messages", value: "\(model.messageCount)")

                Button {
                    Task { await exportHistory() }
                } label: {
                    Label(isExporting ? "Exporting\u{2026}" : "Export History to JSON\u{2026}", systemImage: "square.and.arrow.up")
                }
                .disabled(isExporting || model.messageCount == 0)

                if let exportStatus {
                    Text(exportStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button(role: .destructive) {
                    isPresentingClearConfirm = true
                } label: {
                    Label(isClearing ? "Clearing\u{2026}" : "Clear All Message History\u{2026}", systemImage: "trash")
                }
                .disabled(isClearing || model.messageCount == 0)
            }
        }
        .formStyle(.grouped)
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
