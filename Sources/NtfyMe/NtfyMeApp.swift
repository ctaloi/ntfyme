import SwiftUI

@main
struct NtfyMeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The standard Settings scene (spec §7), which is also what puts
        // `showSettingsWindow:` on the responder chain for
        // `AppDelegate.openSettings()` to send.
        //
        // The model is built by the delegate when the store opens, which
        // happens after this scene is constructed — hence the optional and
        // the observed delegate rather than a value read once at init.
        Settings {
            if let model = appDelegate.settingsModel {
                SettingsView(model: model)
            } else {
                // Only reachable when the store failed to open, in which case
                // the menu bar already says so. Sized to match SettingsView so
                // the window does not resize if the model arrives late.
                Text("NtfyMe couldn't open its message archive.")
                    .frame(width: 520, height: 440)
            }
        }
    }
}
