import Foundation
import NtfyKit

/// State behind the popover, refreshed on demand rather than observed live —
/// there is no store change stream (see `MenuBarController`'s doc comment).
/// The view reads this; `MenuBarController` decides when `refresh()` runs.
@MainActor
final class MenuBarViewModel: ObservableObject {
    /// How the recent-messages query and the connection status are fetched.
    /// A struct of closures rather than a protocol so the wiring pass can
    /// hand in whatever it already has (a `MessageStore` call, a coordinator
    /// snapshot) without this file depending on `ConnectionCoordinator` or
    /// any type outside `NtfyKit`'s published API.
    struct Dependencies {
        var recentMessages: @Sendable () async throws -> [MessageSnapshot]
        var unreadCount: @Sendable () async throws -> Int
        var connectionStatuses: @Sendable () async -> [MenuBarServerStatus]
        var markRead: @Sendable ([String], Bool) async throws -> Void
        var markAllRead: @Sendable () async throws -> Void
    }

    @Published private(set) var groups: [MenuBarTopicGroup] = []
    @Published private(set) var unreadCount = 0
    @Published private(set) var serverStatuses: [MenuBarServerStatus] = []
    /// A fixed, user-facing string when a refresh fails — never
    /// `error.localizedDescription`: a SwiftData/Cocoa error's description
    /// can embed the store's on-disk path, and this repository is public.
    /// The real error goes to `Log.app` as domain/code only, matching every
    /// other error site in this app (see `Log.swift`).
    @Published private(set) var loadErrorMessage: String?
    /// Client-side filter over `groups`, typed into the popover's search
    /// field. Matches title or body, the same two fields
    /// `MessageQuery.searchText` matches server-side — this just runs it
    /// over the ~50 snapshots already in memory instead of another store
    /// round trip.
    @Published var searchText = ""

    var connectivity: MenuBarConnectivity { .summarize(serverStatuses) }

    /// `Server.name` for a group's header, so "alerts" on two servers reads
    /// as two distinct sections rather than one merged list. `nil` when the
    /// server isn't in the latest status fetch (e.g. removed since, or
    /// statuses haven't loaded yet) — the caller falls back to the topic
    /// name alone.
    func serverName(for serverID: UUID) -> String? {
        serverStatuses.first { $0.serverID == serverID }?.name
    }

    /// Groups filtered by `searchText`, case-insensitive, over title or body.
    /// Topics with no matching message are dropped entirely rather than
    /// shown empty.
    var filteredGroups: [MenuBarTopicGroup] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return groups }
        return groups.compactMap { group in
            let matches = group.messages.filter {
                $0.body.localizedCaseInsensitiveContains(query) ||
                ($0.title?.localizedCaseInsensitiveContains(query) ?? false)
            }
            return matches.isEmpty ? nil : MenuBarTopicGroup(
                serverID: group.serverID, topic: group.topic, messages: matches)
        }
    }

    private let dependencies: Dependencies

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    /// Re-fetches everything the popover shows. Safe to call whether or not
    /// the popover is visible — the badge and slashed-icon states depend on
    /// this running, not on the popover being open (`MenuBarController`
    /// exposes it as `refreshNow()` for exactly that).
    func refresh() async {
        serverStatuses = await dependencies.connectionStatuses()

        do {
            async let messages = dependencies.recentMessages()
            async let unread = dependencies.unreadCount()
            groups = MenuBarTopicGroup.group(try await messages)
            unreadCount = try await unread
            loadErrorMessage = nil
        } catch {
            let ns = error as NSError
            Log.app.error("menu bar refresh failed: \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
            // Deliberately does not clear `groups`/`unreadCount`: an empty
            // list would look identical to "no messages", which is exactly
            // the silent failure spec §10 forbids. The stale-but-labeled data
            // stays up, `loadErrorMessage` says the refresh failed, and the
            // view is responsible for showing both.
            loadErrorMessage = "Couldn't refresh messages."
        }
    }

    /// Marks one message read and refreshes so its row and the badge update
    /// together. A no-op if it is already read, so opening the same row
    /// twice does not issue a redundant store write.
    func markRead(_ message: MessageSnapshot) {
        guard !message.isRead else { return }
        Task {
            do {
                try await dependencies.markRead([message.id], true)
                await refresh()
            } catch {
                let ns = error as NSError
                Log.app.error("mark-read failed: \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
                loadErrorMessage = "Couldn't mark that message read."
            }
        }
    }

    func markAllAsRead() {
        Task {
            do {
                try await dependencies.markAllRead()
                await refresh()
            } catch {
                let ns = error as NSError
                Log.app.error("mark-all-read failed: \(ns.domain, privacy: .public) \(ns.code, privacy: .public)")
                loadErrorMessage = "Couldn't mark messages read."
            }
        }
    }
}
