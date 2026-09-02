import SwiftUI

/// Root of the standard SwiftUI `Settings` scene (spec §7), tabbed exactly as
/// specified: General, Servers, Notifications, Advanced. All four tabs share
/// one `SettingsModel` — see its doc comment for why that is load-bearing,
/// not just convenient — so the wiring pass constructs a single instance and
/// hands it here.
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
