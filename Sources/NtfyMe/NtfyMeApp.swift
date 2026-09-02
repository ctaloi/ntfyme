import SwiftUI

@main
struct NtfyMeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            // Replaced with the real settings tabs in a later plan.
            Text("NtfyMe")
                .padding()
                .frame(width: 320, height: 120)
        }
    }
}
