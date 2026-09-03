import SwiftUI

@main
struct NtfyMeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Declared only because `App` requires at least one `Scene` — this
        // body is not how Settings actually reaches the screen. The scene's
        // own auto-wired ⌘,/"Settings…" command sends `showSettingsWindow:`,
        // which has nothing to answer it from this app's usual
        // no-key-window, `.accessory` state (see `SettingsWindowController`'s
        // doc comment — the same problem `AppDelegate.openSettings()` exists
        // to route around for every other entry point). `.commands` below
        // replaces that command outright with one that calls
        // `openSettings()` directly, so this scene's content is never shown
        // by the system and `SettingsWindowController` is the one and only
        // path to a Settings window.
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
        .commands {
            // ⌘N. `replacing: .newItem` rather than adding to it: the
            // default group is "New Window", which this app has no concept
            // of — its windows are one History, one Settings, one Compose,
            // each a singleton its controller owns.
            CommandGroup(replacing: .newItem) {
                Button("New Message…") {
                    appDelegate.openCompose()
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    appDelegate.openSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
