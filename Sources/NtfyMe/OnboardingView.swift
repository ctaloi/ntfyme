import SwiftUI

/// First-run pane, shown once before any server is configured. Its only job
/// is to explain what NtfyMe does with notifications and then trigger the
/// real authorization prompt — spec §6: "Authorization is requested after a
/// short explanatory onboarding pane, never as a cold prompt on first
/// launch."
///
/// This file deliberately never imports `UserNotifications` and never
/// references `UNUserNotificationCenter`. The actual authorization call
/// belongs to `NotificationPresenter.requestAuthorization()`; the wiring
/// pass hands it in as `onRequestAuthorization` so this view structurally
/// cannot bypass it or call the system API directly.
struct OnboardingView: View {
    /// Wired to `NotificationPresenter.requestAuthorization()`. Returns
    /// whether the system granted permission, shown to the user here; not
    /// otherwise acted on by this view.
    let onRequestAuthorization: () async -> Bool
    /// Called once the flow is finished, whether or not authorization was
    /// granted, so the wiring pass can dismiss this pane and continue launch
    /// either way. Not called by "Not Now" — see `onSkip`.
    let onFinish: () -> Void
    /// Called for "Not Now": skips the prompt for this launch without
    /// invoking `onRequestAuthorization` at all.
    let onSkip: () -> Void

    @State private var isRequesting = false
    @State private var deniedMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "bell.badge")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            Text("Stay Notified")
                .font(.title2)
                .bold()

            VStack(alignment: .leading, spacing: 12) {
                Text("NtfyMe shows a macOS notification for messages published to the topics you subscribe to. You choose which servers and topics to follow, and you can mute any of them or turn off alerts entirely at any time in Settings.")

                // Spec §9: stated here, ahead of the first server or topic
                // being added, and repeated again at the point a topic is
                // actually added (Settings \u{2192} Servers).
                Text("On public ntfy.sh, a topic name works like a password \u{2014} anyone who knows it can read and publish to it. Prefer a long, hard-to-guess topic name, or a private server, for anything sensitive.")
                    .foregroundStyle(.secondary)
            }
            .font(.body)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 380)

            if let deniedMessage {
                Text(deniedMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 380)
            }

            HStack(spacing: 12) {
                Button("Not Now") {
                    onSkip()
                }
                .accessibilityLabel("Skip notification setup for now")

                Button {
                    Task { await requestAuthorization() }
                } label: {
                    if isRequesting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Enable Notifications")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isRequesting)
                .accessibilityLabel("Enable notifications")
            }
        }
        .padding(32)
        .frame(width: 460)
    }

    private func requestAuthorization() async {
        isRequesting = true
        let granted = await onRequestAuthorization()
        isRequesting = false
        if !granted {
            deniedMessage = "Notifications aren't enabled. You can turn them on later in System Settings or NtfyMe's Settings."
        }
        onFinish()
    }
}
