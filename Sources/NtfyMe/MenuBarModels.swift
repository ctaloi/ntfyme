import Foundation
import NtfyKit

/// One server's connection state, as the wiring pass reports it to the menu
/// bar. `ConnectionCoordinator.state(forServer:)` is pull-only and there is
/// no store change stream, so this is handed in rather than fetched here —
/// whoever owns the coordinator and the server list assembles this.
struct MenuBarServerStatus: Sendable, Equatable, Identifiable {
    var id: UUID { serverID }
    let serverID: UUID
    /// `Server.name`, the user-chosen display label — not a hostname or URL.
    let name: String
    let state: ConnectionState
}

/// Coarse connectivity read for the status item icon and the popover's
/// status row. Deliberately not just `ConnectionState` re-exported: the icon
/// only has two shapes to pick between (spec §7: badged, or a slashed
/// "disconnected" variant), and folding N servers' states down to that
/// choice is exactly the kind of logic worth a single, pure, named place.
enum MenuBarConnectivity: Sendable, Equatable {
    /// No server is configured yet. Distinct from `.needsAttention`: a fresh
    /// install should not look broken.
    case noServers
    case allConnected
    case someConnected
    case connecting
    case disconnected
    /// At least one server is `.unauthorized` — the state a retry cannot fix,
    /// only a credential change can. Called out ahead of plain "offline" so
    /// the status row can say "sign-in needed" rather than "reconnecting".
    case needsAttention

    /// Worst-first over every server's state. A single pure function so the
    /// precedence lives in one place instead of being re-derived at each call
    /// site.
    static func summarize(_ statuses: [MenuBarServerStatus]) -> MenuBarConnectivity {
        guard !statuses.isEmpty else { return .noServers }
        let states = statuses.map(\.state)

        if states.contains(.unauthorized) { return .needsAttention }
        if states.allSatisfy({ $0 == .open }) { return .allConnected }
        if states.contains(.open) { return .someConnected }
        if states.contains(.connecting) || states.contains(.idle) {
            return .connecting
        }
        // Everything left is `.degraded` or `.backoff` on every server.
        return .disconnected
    }

    /// Fixed, short label shared by the status item's accessibility text and
    /// the popover's connection row, so the two surfaces never drift apart.
    var statusText: String {
        switch self {
        case .noServers: "No servers configured"
        case .allConnected: "Connected"
        case .someConnected: "Partially connected"
        case .connecting: "Connecting"
        case .disconnected: "Disconnected"
        case .needsAttention: "Sign-in needed"
        }
    }
}

extension ConnectionState {
    /// A short, user-facing reason for the popover's connection row — `nil`
    /// for `.open`, which has nothing to report there. Deliberately more
    /// specific than `MenuBarConnectivity.statusText`: that type folds every
    /// server down to one aggregate word for the icon and the one-line
    /// summary, but a user looking at a broken connection needs to know
    /// *which* server and *why* — "rate limited" resolves itself,
    /// "sign-in needed" never will without a credential change, and
    /// "retrying" is already in progress. Collapsing all of those to
    /// "Disconnected" was the actual bug this exists to fix.
    var problemLabel: String? {
        switch self {
        case .open: nil
        case .idle: "Idle"
        case .connecting: "Connecting…"
        case .unauthorized: "Sign-in needed"
        case .backoff: "Retrying…"
        case .degraded(let reason): reason.problemLabel
        }
    }

    /// A rejected credential is terminal until the user changes it — retrying
    /// only burns rate limit (see `ConnectionState.unauthorized`'s own doc
    /// comment). Every other problem state can plausibly be helped by a
    /// retry, including `.backoff`, which is already retrying on its own but
    /// where a user-initiated retry just jumps the queue rather than waiting
    /// out the delay.
    var canRetry: Bool { self != .unauthorized }
}

extension DegradedReason {
    var problemLabel: String {
        switch self {
        case .rateLimited: "Rate limited"
        case .historyGap: "Some history may be missing"
        case .keepaliveTimeout: "Not responding"
        case .invalidSince: "Reconnecting…"
        case .httpError(let status): "Server error (\(status))"
        case .unclassified: "Connection error"
        case .network(let failure): failure.problemLabel
        }
    }
}

extension DegradedReason.NetworkFailure {
    var problemLabel: String {
        switch self {
        case .offline: "Offline"
        case .timedOut: "Timed out"
        case .cannotConnect: "Can't connect"
        case .cannotFindHost: "Can't find host"
        case .connectionLost: "Connection lost"
        case .secureConnectionFailed: "Secure connection failed"
        case .cancelled: "Cancelled"
        case .other: "Network error"
        }
    }
}

/// Recent messages for one topic, newest first, capped to what the popover
/// has room to show.
struct MenuBarTopicGroup: Sendable, Equatable, Identifiable {
    var id: String { "\(serverID.uuidString)/\(topic)" }
    let serverID: UUID
    let topic: String
    let messages: [MessageSnapshot]

    /// Groups `snapshots` (expected newest-first, as `MessageStore.search`
    /// returns them) by `(serverID, topic)`, keeping each group's messages in
    /// their incoming order and capping each group at `perTopicLimit`.
    ///
    /// Group order follows first appearance in `snapshots` — since the input
    /// is newest-first, that is the topic's most recent message time,
    /// without a second sort pass.
    static func group(_ snapshots: [MessageSnapshot],
                      perTopicLimit: Int = 3) -> [MenuBarTopicGroup] {
        var order: [String] = []
        var buckets: [String: (serverID: UUID, topic: String, messages: [MessageSnapshot])] = [:]

        for snapshot in snapshots {
            let key = "\(snapshot.serverID.uuidString)/\(snapshot.topic)"
            if var bucket = buckets[key] {
                if bucket.messages.count < perTopicLimit {
                    bucket.messages.append(snapshot)
                }
                buckets[key] = bucket
            } else {
                order.append(key)
                buckets[key] = (snapshot.serverID, snapshot.topic, [snapshot])
            }
        }

        return order.compactMap { key in
            guard let bucket = buckets[key] else { return nil }
            return MenuBarTopicGroup(serverID: bucket.serverID, topic: bucket.topic,
                                     messages: bucket.messages)
        }
    }
}
