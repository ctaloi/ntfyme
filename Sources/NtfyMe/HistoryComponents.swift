import SwiftUI
import NtfyKit

/// A quiet priority indicator: a small SF Symbol tinted by urgency. Priority
/// is meant to be noticed at a glance, not shout — spec's design guidance —
/// so this never uses a hard-coded color, only semantic ones that adapt to
/// Dark Mode and Increase Contrast.
struct PriorityPill: View {
    let priority: NtfyPriority

    var body: some View {
        Label(priority.label, systemImage: symbolName)
            .labelStyle(.iconOnly)
            .font(.caption)
            .foregroundStyle(tint)
            .help(priority.label)
            .accessibilityLabel(Text("Priority: \(priority.label)"))
    }

    private var symbolName: String {
        switch priority {
        case .min: return "chevron.down"
        case .low: return "chevron.down"
        case .default: return "circle"
        case .high: return "exclamationmark"
        case .max: return "exclamationmark.2"
        }
    }

    private var tint: Color {
        switch priority {
        case .min, .low: return .secondary
        case .default: return .secondary
        case .high: return .orange
        case .max: return .red
        }
    }
}

extension NtfyPriority {
    var label: String {
        switch self {
        case .min: return "Min"
        case .low: return "Low"
        case .default: return "Default"
        case .high: return "High"
        case .max: return "Max"
        }
    }
}

/// A small rounded chip for one message tag.
struct TagChip: View {
    let tag: String

    var body: some View {
        Text(tag)
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.15), in: Capsule())
            .foregroundStyle(.secondary)
            .accessibilityLabel(Text("Tag: \(tag)"))
    }
}

/// A centered icon + message, for empty and loading states that say
/// something useful rather than leaving a blank pane.
struct HistoryStatusView: View {
    let systemImage: String
    let title: String
    let message: String?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let message {
                Text(message)
            }
        }
    }
}
