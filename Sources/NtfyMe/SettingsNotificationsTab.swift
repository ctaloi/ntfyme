import SwiftUI
import AppKit
import NtfyKit

/// Spec §7: "default priority threshold, sound, and a shortcut to System
/// Settings for the app's notification permission."
///
/// Only "record only, never alert" is wired to real behavior today —
/// `Preferences.recordOnlyNeverAlert` is read end-to-end by
/// `NotificationRouter.handleStored` via `NotificationDecision`. The default
/// priority threshold and sound toggle below are display-only: they persist
/// to `UserDefaults` under this tab's own keys, but nothing in
/// `NotificationDecision` or `Ingest` reads them yet — there is no field for
/// either on `Preferences`, and adding one is outside `Settings*.swift`. See
/// the wave2-settings report for exactly what a wiring pass needs to do to
/// make them take effect (most likely: seed a new subscription's
/// `TopicAlertSettings.minAlertPriority` from the threshold, and have
/// `NotificationPresenter.present` skip `content.sound` when sound is off).
struct SettingsNotificationsTab: View {
    let model: SettingsModel

    @AppStorage("settings.notifications.defaultMinPriority") private var defaultMinPriority = NtfyPriority.default.rawValue
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
