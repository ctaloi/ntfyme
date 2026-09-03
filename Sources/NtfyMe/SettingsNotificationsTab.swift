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
/// see its doc comment.
///
/// **No "play a sound" toggle.** Wiring it needs a new `Preferences` field
/// plus changes to `NotificationDecision`/`NotificationRequest.playsSound` —
/// new `NtfyKit` surface with no test coverage, decided against at the merge
/// gate. Sound stays governed entirely by priority, per spec §6's table. Can
/// come back with its own plumbing and tests later.
///
/// **System Permission reads the live status, not a static how-to.** A tab
/// whose entire job is answering "why isn't this alerting" said nothing
/// about that when permission was actually denied — identical copy whether
/// authorized, denied, or never asked. `model.notificationAuthorization`
/// (refreshed on every appearance, since the user can change it in System
/// Settings while this window stays open) drives three distinct states
/// below: denied says so plainly and points at the fix; not-determined
/// offers to ask directly, through the same `NotificationPresenter
/// .requestAuthorization()` onboarding uses, rather than sending the user to
/// System Settings for a prompt the app has never made; authorized is a
/// quiet confirmation for anyone debugging.
struct SettingsNotificationsTab: View {
    let model: SettingsModel

    @AppStorage(SettingsDefaultsKey.defaultMinPriority) private var defaultMinPriority = NtfyPriority.default.rawValue
    @State private var isRequestingAuthorization = false

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
            } header: {
                Text("Defaults for New Topics")
            } footer: {
                Text("Applies when a topic is added. Each topic's own mute and priority can still be changed in Settings \u{2192} Servers.")
            }

            Section("System Permission") {
                permissionStatusView
            }
        }
        .formStyle(.grouped)
        .onAppear {
            Task { await model.refreshNotificationAuthorization() }
        }
    }

    @ViewBuilder
    private var permissionStatusView: some View {
        switch model.notificationAuthorization {
        case .authorized:
            Label("Notifications are allowed.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Notifications are allowed")

        case .denied:
            Label("Notifications are turned off for NtfyMe in System Settings \u{2014} this is why nothing is alerting.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityLabel("Notifications are denied")
            Button {
                openNotificationSettings()
            } label: {
                Label("Open Notification Settings\u{2026}", systemImage: "arrow.up.forward.app")
            }

        case .notDetermined:
            Text("NtfyMe hasn't asked for notification permission yet.")
                .foregroundStyle(.secondary)
            Button {
                Task { await enableNotifications() }
            } label: {
                if isRequestingAuthorization {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Enable Notifications")
                }
            }
            .disabled(isRequestingAuthorization)
            .accessibilityLabel("Enable notifications")
        }
    }

    private func enableNotifications() async {
        isRequestingAuthorization = true
        await model.enableNotifications()
        isRequestingAuthorization = false
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
