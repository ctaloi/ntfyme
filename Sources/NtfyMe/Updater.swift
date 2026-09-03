import AppKit
import Sparkle

/// Wraps Sparkle, the auto-update framework.
///
/// **The updater only starts when the app is configured for it**: both
/// `SUFeedURL` and a non-empty `SUPublicEDKey` must be in Info.plist, which
/// `Scripts/build-app.sh` fills from `Scripts/config.sh`. A dev build with
/// no release key configured runs with no updater at all — no scheduled
/// checks, no error dialogs about a missing appcast — and the Check for
/// Updates menu item quietly does nothing. That keeps the dev loop clean
/// while release builds (built with the key set) get the full machinery.
///
/// Sparkle schedules a check every 24 hours (`SUEnableAutomaticChecks` in
/// Info.plist) and prompts before installing; silent auto-install was
/// deliberately not enabled (`SUAutomaticallyUpdate`) — for a young app
/// the user should see and approve each jump.
@MainActor
final class Updater {
    private var controller: SPUStandardUpdaterController?

    /// Whether Info.plist carries a usable updater configuration.
    var isConfigured: Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let feed = info["SUFeedURL"] as? String, !feed.isEmpty else { return false }
        guard let key = info["SUPublicEDKey"] as? String, !key.isEmpty else { return false }
        return true
    }

    /// Idempotent: starts Sparkle's background schedule once, on first
    /// launch of a configured build.
    func start() {
        guard isConfigured, controller == nil else { return }
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    func checkForUpdates() {
        guard let controller else { return }
        controller.checkForUpdates(nil)
    }
}
