import Foundation
import NtfyKit

/// Which slice of the archive the sidebar has selected.
enum HistoryScope: Hashable, Sendable {
    case all
    case server(UUID)
    case topic(serverID: UUID, topic: String)

    var serverID: UUID? {
        switch self {
        case .all: return nil
        case .server(let id): return id
        case .topic(let serverID, _): return serverID
        }
    }

    var topic: String? {
        if case .topic(_, let topic) = self { return topic }
        return nil
    }
}

/// The list's priority filter. `MessageQuery.minPriority` is a lower bound,
/// so every case below reads as "this priority and everything more urgent".
enum PriorityFilter: Int, CaseIterable, Identifiable, Sendable, Equatable {
    case any
    case low
    case defaultAndAbove
    case high
    case max

    var id: Int { rawValue }

    var minPriority: Int? {
        switch self {
        case .any: return nil
        case .low: return NtfyPriority.low.rawValue
        case .defaultAndAbove: return NtfyPriority.default.rawValue
        case .high: return NtfyPriority.high.rawValue
        case .max: return NtfyPriority.max.rawValue
        }
    }

    var label: String {
        switch self {
        case .any: return "Any Priority"
        case .low: return "Low and above"
        case .defaultAndAbove: return "Default and above"
        case .high: return "High and above"
        case .max: return "Max only"
        }
    }
}

/// The list's date-range filter. `.custom` carries explicit bounds for the
/// date-picker popover; the presets below are resolved against "now" at
/// query time, not frozen when selected.
enum DateRangeFilter: Hashable, Sendable {
    case any
    case today
    case last7Days
    case last30Days
    case custom(since: Date?, until: Date?)

    var label: String {
        switch self {
        case .any: return "Any Time"
        case .today: return "Today"
        case .last7Days: return "Last 7 Days"
        case .last30Days: return "Last 30 Days"
        case .custom: return "Custom Range"
        }
    }

    /// Resolves the filter into concrete `since`/`until` bounds. Pure and
    /// deterministic given `now` and `calendar` — kept as a free function
    /// (rather than inlined into the view model) so it is the one piece of
    /// this surface's date-bucketing logic that is unit-testable in
    /// isolation, independent of the store or the view.
    func bounds(now: Date, calendar: Calendar = .current) -> (since: Date?, until: Date?) {
        switch self {
        case .any:
            return (nil, nil)
        case .today:
            return (calendar.startOfDay(for: now), nil)
        case .last7Days:
            return (calendar.date(byAdding: .day, value: -7, to: now), nil)
        case .last30Days:
            return (calendar.date(byAdding: .day, value: -30, to: now), nil)
        case .custom(let since, let until):
            return (since, until)
        }
    }
}

/// Builds the `MessageQuery` the list issues, from the sidebar scope and the
/// list's filter state. Pure — no store access, no view-model state beyond
/// what is passed in — so it is independently testable and is the one place
/// this file assembles a query, rather than each call site rebuilding one by
/// hand.
enum HistoryQueryBuilder {
    static func makeQuery(scope: HistoryScope, searchText: String, priority: PriorityFilter,
                           tag: String, dateRange: DateRangeFilter, now: Date,
                           limit: Int, offset: Int) -> MessageQuery {
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        let (since, until) = dateRange.bounds(now: now)
        return MessageQuery(
            serverID: scope.serverID,
            topic: scope.topic,
            searchText: trimmedSearch.isEmpty ? nil : trimmedSearch,
            minPriority: priority.minPriority,
            tag: trimmedTag.isEmpty ? nil : trimmedTag,
            unreadOnly: false,
            since: since,
            until: until,
            limit: limit,
            offset: offset)
    }
}

/// The sidebar's per-server status dot. `MessageStore` has no notion of a
/// live connection — that lives in `ConnectionCoordinator`, owned by
/// `AppGraph`, which this file must not import. `HistoryViewModel.statusProvider`
/// defaults every server to `.unknown`; a later wiring pass sets it to a
/// closure backed by the coordinator's real state.
enum HistoryConnectionStatus: Sendable {
    case unknown
    case connected
    case connecting
    case disconnected

    var symbolName: String {
        switch self {
        case .unknown: return "circle.dotted"
        case .connected: return "circle.fill"
        case .connecting: return "circle.dotted"
        case .disconnected: return "exclamationmark.circle.fill"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .unknown: return "Connection status unknown"
        case .connected: return "Connected"
        case .connecting: return "Connecting"
        case .disconnected: return "Disconnected"
        }
    }
}
