import SwiftUI
import ServiceManagement

/// Spec §7: "launch at login (`SMAppService.mainApp`), retention window,
/// badge behavior."
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

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch NtfyMe at login", isOn: launchAtLoginBinding)
                    .accessibilityHint(Text("Registers NtfyMe as a login item using Service Management."))

                if model.loginItemStatus == .requiresApproval {
                    Label(
                        "Needs approval in System Settings \u{2192} General \u{2192} Login Items.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }

            Section("History") {
                LabeledContent("Keep messages for") {
                    HStack {
                        TextField("Days", text: $retentionDaysText)
                            .frame(width: 56)
                            .multilineTextAlignment(.trailing)
                            .onSubmit(applyRetention)
                            .accessibilityLabel("Retention window, in days")
                        Text("days").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Keep up to") {
                    HStack {
                        TextField("Messages", text: $maxPerTopicText)
                            .frame(width: 72)
                            .multilineTextAlignment(.trailing)
                            .onSubmit(applyRetention)
                            .accessibilityLabel("Maximum stored messages per topic")
                        Text("messages per topic").foregroundStyle(.secondary)
                    }
                }
                Text("Whichever limit is reached first applies. Changes take effect on the next retention pass.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Menu Bar") {
                Toggle("Badge the menu bar icon with the unread count", isOn: $badgeEnabled)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: syncRetentionFields)
        .onChange(of: model.prefs.retention) { _, _ in syncRetentionFields() }
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
}
