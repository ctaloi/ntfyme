import SwiftUI

/// Shared layout pieces for the Settings tabs, replacing `Form`'s two
/// built-in styles: `.formStyle(.grouped)` (the rounded-card look — read as
/// "System Settings.app ported from iOS" against the rest of this app's
/// native-first redesign) and `.formStyle(.columns)` (the traditional
/// label-left/control-right layout — but its label column is a fixed
/// trailing-aligned width, and this app's longer labels — "Badge the menu
/// bar icon with the unread count" — overflowed past the window's left edge
/// rather than wrapping). Plain, left-aligned content with explicit spacing
/// gives predictable layout for labels of any length and full control over
/// type scale, matching `Tests/NtfyMeTests/RedesignMockups.swift`'s type
/// scale and spacing rhythm rather than System Settings' rather than
/// inheriting either `Form` style's built-in choices.
struct SettingsSection<Content: View>: View {
    let title: String
    /// Optional SF Symbol drawn before the title — a quiet wayfinding cue
    /// that also lets each section's *voice* differ (a bell for alerts, a
    /// clock for retention) where a bare text heading made every section
    /// read the same. `nil` where an icon would be noise.
    var icon: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            VStack(alignment: .leading, spacing: 10) {
                content
            }
        }
    }
}

/// A section's explanatory line — the plain-text footnotes `Form`'s section
/// footer used to carry (e.g. "Whichever limit is reached first applies").
struct SettingsFootnote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One row: a label on the left, arbitrary control content on the right.
/// Wraps rather than truncates when the window is narrow — the failure mode
/// `.formStyle(.columns)` had instead was overflow, not wrapping.
struct SettingsRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 13))
            Spacer(minLength: 12)
            content
        }
    }
}

extension View {
    /// The one place every Settings root paints its own ground, rather than
    /// each view remembering to add `.background(Color(nsColor:
    /// .windowBackgroundColor))` itself. This project has now found four
    /// separate un-painted-ground bugs by eye — General's empty state, two
    /// spots in the server editor sheet, and the Servers tab's footer bar —
    /// each only visible once something (dark mode, a taller window) left
    /// visible empty space for the gap to show through. A single named
    /// modifier, applied at every Settings view's root, is cheaper than
    /// finding a fifth one.
    func settingsBackground() -> some View {
        background(Color(nsColor: .windowBackgroundColor))
    }
}
