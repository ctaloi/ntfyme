import SwiftUI
import AppKit
import NtfyKit

/// Spec §7: "default priority threshold, sound, and a shortcut to System
/// Settings for the app's notification permission."
///
/// "Record only, never alert" and "Minimum priority" are both wired to real
/// behavior. `Preferences.recordOnlyNeverAlert` is read end-to-end by
/// `NotificationRouter.handleStored` via `NotificationDecision`, and
/// `SettingsModel.addTopic` seeds a newly added topic's
/// `TopicAlertSettings.minAlertPriority` from this picker's stored value —
/// see its doc comment. "Play a sound" is still display-only: it persists
/// under its own `UserDefaults` key, but nothing in `NotificationPresenter`
/// reads it yet, and the user has been asked whether to wire it or remove
/// it (see the wave2 report) — do not act on it without that answer.
struct SettingsNotificationsTab: View {
    let model: SettingsModel

    @AppStorage(SettingsDefaultsKey.defaultMinPriority) private var defaultMinPriority = NtfyPriority.default.rawValue
    @AppStorage("settings.notifications.soundEnabled") private var soundEnabled = true

    var body: some View {
        Form {
            Section("Alerts") {
                Toggle("Record only \u{2014} never alert", isOn: recordOnlyBinding)
                    .help("Every message is still saved to history; nothing raises a notification.")
            }

            Section {
                Picker("Minimum priority", selection: $defaultMinPriority) {
                    ForEach(NtfyPriority.allCases, id: \.rawValue) { priority in
                        Text(priorityLabel(priority)).tag(priority.rawValue)
                    }
                }
                Toggle("Play a sound", isOn: $soundEnabled)
            } header: {
                Text("Defaults for New Topics")
            } footer: {
                Text("Applies when a topic is added. Each topic's own mute and priority can still be changed in Settings \u{2192} Servers.")
            }

            Section("System Permission") {
                Button {
                    openNotificationSettings()
                } label: {
                    Label("Open Notification Settings\u{2026}", systemImage: "arrow.up.forward.app")
                }
                Text("NtfyMe must be allowed to send notifications in System Settings for alerts to appear.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var recordOnlyBinding: Binding<Bool> {
        Binding(
            get: { model.prefs.recordOnlyNeverAlert },
            set: { model.setRecordOnlyNeverAlert($0) }
        )
    }

    private func priorityLabel(_ priority: NtfyPriority) -> String {
        switch priority {
        case .min: "Min"
        case .low: "Low"
        case .default: "Default"
        case .high: "High"
        case .max: "Max"
        }
    }

    /// Opens System Settings' Notifications pane directly via a URL scheme.
    /// This file never imports `UserNotifications` and never references
    /// `UNUserNotificationCenter` — that stays entirely inside
    /// `NotificationPresenter`, per spec.
    private func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else { return }
        NSWorkspace.shared.open(url)
    }
}
