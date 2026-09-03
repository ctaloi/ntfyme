import SwiftUI

/// The Settings window's root content, tabbed exactly as spec §7 specifies:
/// General, Servers, Notifications, Advanced. All four tabs share one
/// `SettingsModel` — see its doc comment for why that is load-bearing, not
/// just convenient — so the wiring pass constructs a single instance and
/// hands it here.
///
/// Hosted by `SettingsWindowController`, not the SwiftUI `Settings` scene —
/// see that controller's doc comment for why: as a menu-bar accessory this
/// app is frequently not the active application, and the scene's
/// `showSettingsWindow:` had nothing on the responder chain to answer it.
struct SettingsView: View {
    let model: SettingsModel

    var body: some View {
        TabView {
            SettingsGeneralTab(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }

            SettingsServersTab(model: model)
                .tabItem { Label("Servers", systemImage: "server.rack") }

            SettingsNotificationsTab(model: model)
                .tabItem { Label("Notifications", systemImage: "bell.badge") }

            SettingsAdvancedTab(model: model)
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 520, height: 440)
        .task { await model.refresh() }
        .alert("Settings", isPresented: errorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { isPresented in if !isPresented { model.errorMessage = nil } }
        )
    }
}
