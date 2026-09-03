import Testing
import SwiftUI
@testable import NtfyMe

/// A SwiftUI root hosted directly in an `NSHostingView` has nothing behind it
/// painting a surface. If it does not paint its own, it renders transparent,
/// and what the user sees is whatever is behind it — in a real window, the
/// light backing. In dark mode that means near-white text on white: the pane
/// is there, laid out correctly, and completely unreadable.
///
/// This shipped three times in this app before anything caught it — the menu
/// bar popover, the History detail pane, and the onboarding pane — because the
/// light render looks perfect and every indirect instrument gets it wrong:
///
/// - **Byte counts** do not catch it. A broken render is *larger* than a
///   correct one.
/// - **A light-vs-dark byte divergence** does not catch it. Measured, the
///   broken pair diverges *more* than the correct pair (13,707 vs 2,084), so
///   the comparison is inverted and no threshold works.
/// - **A distinct-colour count** does not catch it once the render is
///   composited onto a ground, because the elements that remain visible are
///   plenty.
///
/// Alpha is the property that actually differs, so it is what these assert.
/// A view that paints its own ground is opaque; one that does not is not.
/// Measured: correct 1.0, background removed 0.053.

/// Well below a correct render (1.0) and well above a broken one (0.053).
private let opaqueThreshold = 0.9

@MainActor @Test func theOnboardingPanePaintsItsOwnBackground() throws {
    for scheme in [ColorScheme.light, .dark] {
        let name = "onboarding-\(scheme == .dark ? "dark" : "light").png"
        _ = try renderSnapshot(
            OnboardingView(onRequestAuthorization: { true }, onFinish: {}, onSkip: {}),
            size: CGSize(width: 420, height: 340), colorScheme: scheme, to: name)

        let alpha = try meanAlpha(ofPNGAt: "/tmp/ntfyshots/\(name)")
        #expect(alpha > opaqueThreshold,
                "\(name) has mean alpha \(alpha) — this root paints no background of its own, so in a real window its text renders against the window's light backing. In dark mode that is near-white on white and invisible. This is the first thing a new user sees.")
    }
}

/// The appearance check, kept alongside the opacity one because they fail for
/// different reasons: a pane could paint an opaque ground of entirely the
/// wrong colour and satisfy the alpha assertion.
@MainActor @Test func theOnboardingPaneHonoursTheAppearance() throws {
    let light = try meanLuminance(ofPNGAt: "/tmp/ntfyshots/onboarding-light.png")
    let dark = try meanLuminance(ofPNGAt: "/tmp/ntfyshots/onboarding-dark.png")
    #expect(light > 0.5, "onboarding-light.png mean luminance \(light) — expected a light surface.")
    #expect(dark < 0.5, "onboarding-dark.png mean luminance \(dark) — expected a dark surface.")
    #expect(light > dark)
}
