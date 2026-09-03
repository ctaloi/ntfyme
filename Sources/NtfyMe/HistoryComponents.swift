import SwiftUI
import NtfyKit

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

extension View {
    /// Fades the trailing ~10% of a horizontally-scrolling row (tag chips,
    /// here) rather than leaving its content clipped hard at the container
    /// edge. Without this, a chip that happens to end mid-word right at the
    /// boundary — e.g. tag text sliced to "urge" — reads as a rendering
    /// fault, not as an invitation to scroll for more; the fade is what
    /// signals "there is more here" instead.
    func fadedTrailingEdge() -> some View {
        mask(
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.88),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .leading, endPoint: .trailing))
    }
}

/// A centered icon + message, for empty and loading states that say
/// something useful rather than leaving a blank pane. `actions` defaults to
/// nothing — most callers (loading, "no message selected", a search error)
/// have no action that makes sense; the filtered-empty state is the one
/// that does (clearing the filters that caused it).
struct HistoryStatusView<Actions: View>: View {
    let systemImage: String
    let title: String
    let message: String?
    @ViewBuilder var actions: Actions

    init(systemImage: String, title: String, message: String?,
        @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.actions = actions()
    }

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let message {
                Text(message)
            }
        } actions: {
            actions
        }
    }
}
