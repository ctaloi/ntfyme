import Testing
import SwiftUI
@testable import NtfyMe

/// A SwiftUI root hosted directly in an `NSHostingView` has nothing behind it
/// painting a surface. If it does not paint its own, it renders *unpainted* —
/// and what the user then sees depends entirely on what happens to be behind
/// it. In the running app that is the window's white backing, so a dark-mode
/// user gets near-white text on white and the entire pane is invisible.
///
/// This shipped three times here before anyone caught it: the menu bar
/// popover, the History detail pane, and the onboarding pane. It survives code
/// review because the light render looks perfect. It also survived a
/// byte-count divergence assertion, because a broken render still *differs*
/// between appearances — the antialiasing changes even when every word is
/// invisible.
///
/// These two tests are a pair and only work as a pair: each appearance must
/// produce a surface of the luminance that appearance implies. An unpainted
/// view fails one or the other depending on how the transparent backing
/// resolves — verified by mutation: deleting the background from
/// `OnboardingView` drops the light render's mean luminance from ~0.93 to
/// 0.002, because nothing is painting the surface at all.
///
/// Asserting only "dark is dark" would be satisfied by a renderer that
/// returned black for everything, which is why the light case is here too.

/// Comfortably above a correct dark render (~0.15) and comfortably below a
/// broken one (~0.95), so this discriminates without being brittle.
private let darkThreshold = 0.5

@MainActor @Test func theOnboardingPaneIsActuallyDarkInDarkMode() throws {
    let path = "/tmp/ntfyshots/onboarding-dark.png"
    _ = try renderSnapshot(
        OnboardingView(onRequestAuthorization: { true }, onFinish: {}, onSkip: {}),
        size: CGSize(width: 420, height: 340), colorScheme: .dark,
        to: "onboarding-dark.png")

    let luminance = try meanLuminance(ofPNGAt: path)
    #expect(luminance < darkThreshold,
            "onboarding-dark.png has mean luminance \(luminance) — expected a dark surface. If this is high, the pane is not painting its own background and its text is invisible against the window. This is the first thing a new user sees.")
}

/// The complement, so the threshold is proven to discriminate rather than
/// merely being satisfied: the same view in light mode must be light. Without
/// this, a test asserting "dark is dark" would also pass if the renderer
/// returned black for everything.
@MainActor @Test func theOnboardingPaneIsLightInLightMode() throws {
    let path = "/tmp/ntfyshots/onboarding-light.png"
    _ = try renderSnapshot(
        OnboardingView(onRequestAuthorization: { true }, onFinish: {}, onSkip: {}),
        size: CGSize(width: 420, height: 340), colorScheme: .light,
        to: "onboarding-light.png")

    let luminance = try meanLuminance(ofPNGAt: path)
    #expect(luminance > darkThreshold,
            "onboarding-light.png has mean luminance \(luminance) — expected a light surface. A near-zero value means the view is painting no background at all, not that it is dark.")
}
