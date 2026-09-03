import SwiftUI
import Testing
@testable import NtfyMe

/// Renders the app icon master at 1024pt. Not a test of behaviour — a build
/// step that happens to live where the rendering harness already works.
///
/// Drawn rather than hand-authored so the shape is reproducible: a macOS
/// icon is a rounded rectangle with continuous corners, inset from the canvas
/// so the system's shadow and alignment grid have room. The proportions here
/// (824 of 1024, ~185 corner radius) are the standard macOS app-icon grid.
private struct AppIcon: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 0.36, green: 0.44, blue: 0.96),
                             Color(red: 0.55, green: 0.30, blue: 0.92)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.18), radius: 18, y: 10)

            // A bell, because that is what the app does. Slightly optically
            // raised: a bell's visual mass sits low, so centring it
            // geometrically makes it look like it has slipped.
            Image(systemName: "bell.fill")
                .font(.system(size: 400, weight: .medium))
                .foregroundStyle(.white)
                .offset(y: -18)
        }
        .frame(width: 1024, height: 1024)
    }
}

@MainActor @Test(requiresSnapshotRendering) func renderAppIconMaster() throws {
    _ = try renderSnapshot(AppIcon(), size: CGSize(width: 1024, height: 1024),
                           to: "appicon-master.png")
}
