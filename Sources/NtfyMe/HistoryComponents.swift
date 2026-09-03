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


/// How a message's time reads in a list row.
///
/// Every row used to show a bare clock time (`Text(snapshot.time, style:
/// .time)`), so a message from last Tuesday and one from four minutes ago
/// were indistinguishable at a glance — the row said "8:04 AM" either way,
/// and in a list sorted by time that is the one thing the column is for.
///
/// Follows Mail's scheme, which is what a Mac user already reads without
/// being taught: something very recent is relative, today is a clock time,
/// yesterday is named, this week is a weekday, and anything older is a
/// date (with the year only when it is not this one).
///
/// `now` is a parameter rather than `Date()` so this is testable at all —
/// every boundary below is a boundary against the current time.
enum MessageTimestamp {
    static func text(for date: Date, now: Date = Date(),
                     calendar: Calendar = .current) -> String {
        let elapsed = now.timeIntervalSince(date)

        // Future-dated messages happen: a publisher's clock can be ahead,
        // and ntfy's `at`/delayed delivery carries the scheduled time. Read
        // as "now" rather than as a negative minute count.
        if elapsed < 60 { return "now" }
        if elapsed < 3600 { return "\(Int(elapsed / 60))m" }

        // `isDateInToday`/`isDateInYesterday` compare against the system
        // clock, not against `now` — so using them here would have made
        // `now` a half-honoured parameter and this function untestable in
        // exactly the two branches most worth testing. Caught by the tests
        // on the first run: a message from "yesterday" relative to a fixed
        // `now` came back as a weekday, because it was not yesterday
        // relative to the real date.
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(.dateTime.hour().minute())
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        // Under a week: the weekday alone is unambiguous and shorter than
        // a date. Seven days rather than "this calendar week", so the
        // column does not change meaning depending on what day it is.
        if elapsed < 7 * 24 * 3600 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(.dateTime.day().month(.abbreviated))
        }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}
