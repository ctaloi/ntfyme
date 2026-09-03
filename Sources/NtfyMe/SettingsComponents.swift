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
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
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
