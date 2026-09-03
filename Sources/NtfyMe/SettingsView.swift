import SwiftUI

/// The Settings window's root content, tabbed: General, Servers,
/// Notifications. All tabs share one `SettingsModel` — see its doc comment
/// for why that is load-bearing, not just convenient — so the wiring pass
/// constructs a single instance and hands it here.
///
/// Three tabs, not spec §7's four: Advanced folded into General once the
/// log-level control was removed left it — see `SettingsGeneralTab`'s doc
/// comment for the reasoning (two tabs both titled "History" is the kind of
/// split that makes people hunt, and a tab holding one thin group was not
/// earning its place in the tab bar).
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
        }
        .frame(width: 640, height: 560)
        .task {
            // Seed before refresh, not after: so a genuinely first-run
            // window shows the seeded ntfy.sh server on its very first
            // paint rather than an empty state that fills in a moment
            // later. See `SettingsModel.seedDefaultServerIfNeeded`'s doc
            // comment for why this is safe to call every time Settings
            // opens (it is a one-shot, flag-gated no-op after the first).
            await model.seedDefaultServerIfNeeded()
            await model.refresh()
        }
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
