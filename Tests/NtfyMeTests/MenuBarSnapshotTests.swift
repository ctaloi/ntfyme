import Testing
import SwiftUI
import Foundation
import NtfyKit
@testable import NtfyKit // for MessageSnapshot's internal memberwise init — canned fixtures only
@testable import NtfyMe

/// Headless visual verification for the menu bar popover, via
/// `renderSnapshot` (see `SnapshotSupport.swift` for why that, and not
/// `ImageRenderer`, is used here). These are not unit tests asserting
/// behavior — `MenuBarConnectivity`/`MenuBarTopicGroup`-style coverage would
/// be that, and doesn't exist yet for the reason `wave2-menubar-report.md`
/// gives. This is "what does it look like", written to `/tmp/ntfyshots/` for
/// a human to look at — but each render still asserts a byte count and, for
/// states expected to differ, that they actually do: a render that succeeds
/// and shows nothing is worse than no test, per the same rule this project
/// applies to negative assertions.
///
/// All content below is invented and generic — this repository is public,
/// and none of it is the user's actual servers, topics, or hostnames.
enum MenuBarFixtures {
    static let homeLabID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let publicID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    static let homeLab = MenuBarServerStatus(serverID: homeLabID, name: "Home Lab", state: .open)
    static let ntfySh = MenuBarServerStatus(serverID: publicID, name: "ntfy.sh", state: .open)

    /// One `alerts` message with a deliberately long body (must wrap, not
    /// overflow), one short read `alerts` message, one message on a
    /// deliberately long topic name (must truncate, not push the popover
    /// wider), and two `backups` messages on the second server — one whose
    /// body contains "certificate", used to exercise the search filter.
    static func messages(now: Date = Date()) -> [MessageSnapshot] {
        [
            snapshot(id: "a1", topic: "alerts", serverID: homeLabID,
                     time: now.addingTimeInterval(-120),
                     title: "Disk usage high",
                     body: "Root partition on nas01 is at 92% capacity. Consider clearing old backups or expanding the volume before it fills completely, which could bring services down without warning.",
                     priority: 4, isRead: false),
            snapshot(id: "a2", topic: "alerts", serverID: homeLabID,
                     time: now.addingTimeInterval(-3600),
                     title: nil,
                     body: "Nightly backup completed successfully.",
                     priority: 1, isRead: true),
            snapshot(id: "c1", topic: "deploys-pipeline-status-notifications", serverID: homeLabID,
                     time: now.addingTimeInterval(-600),
                     title: "Deploy finished",
                     body: "Build #482 deployed to production in 3m12s.",
                     priority: 3, isRead: false),
            snapshot(id: "d1", topic: "backups", serverID: publicID,
                     time: now.addingTimeInterval(-10_800),
                     title: "Backup verification failed",
                     body: "Monthly restore-test for the certificate archive failed checksum validation; investigate before the next rotation.",
                     priority: 5, isRead: false),
            snapshot(id: "d2", topic: "backups", serverID: publicID,
                     time: now.addingTimeInterval(-86_400),
                     title: "Weekly summary",
                     body: "12 jobs completed, 0 failures.",
                     priority: 2, isRead: true),
        ]
    }

    static func snapshot(id: String, topic: String, serverID: UUID, time: Date,
                         title: String?, body: String, priority: Int,
                         isRead: Bool) -> MessageSnapshot {
        MessageSnapshot(id: id, messageID: id, topic: topic, serverID: serverID, time: time,
                        title: title, body: body, priority: priority, tags: [], click: nil,
                        iconURL: nil, contentType: nil, actionsJSON: nil, actions: [],
                        isRead: isRead, attachment: nil)
    }
}

/// Serial call counter for a `Dependencies.recentMessages` closure that
/// needs to succeed once and then fail — simulating a stale-data-plus-error
/// state without a store. `@unchecked Sendable`: only ever touched serially,
/// on the main actor, by the one `MenuBarViewModel` under test — the same
/// justification `PreferencesStore` uses for its own `@unchecked Sendable`.
final class MenuBarFixtureCallCounter: @unchecked Sendable {
    private var count = 0
    func next() -> Int {
        count += 1
        return count
    }
}

struct MenuBarFixtureError: Error {}

@MainActor
private func makeViewModel(messages: [MessageSnapshot], unread: Int,
                           statuses: [MenuBarServerStatus],
                           failFrom failureCallNumber: Int? = nil) -> MenuBarViewModel {
    let counter = MenuBarFixtureCallCounter()
    let dependencies = MenuBarViewModel.Dependencies(
        recentMessages: {
            let call = counter.next()
            if let failureCallNumber, call >= failureCallNumber {
                throw MenuBarFixtureError()
            }
            return messages
        },
        unreadCount: { unread },
        connectionStatuses: { statuses },
        markRead: { _, _ in },
        markAllRead: {})
    return MenuBarViewModel(dependencies: dependencies)
}

@MainActor
private func popoverView(_ viewModel: MenuBarViewModel) -> MenuBarPopoverView {
    MenuBarPopoverView(viewModel: viewModel, onOpenHistory: {}, onOpenSettings: {}, onQuit: {})
}

@MainActor @Test func renderPopulated() async throws {
    let viewModel = makeViewModel(messages: MenuBarFixtures.messages(), unread: 3,
                                  statuses: [MenuBarFixtures.homeLab, MenuBarFixtures.ntfySh])
    await viewModel.refresh()
    #expect(!viewModel.filteredGroups.isEmpty)
    let bytes = try renderSnapshot(popoverView(viewModel), size: MenuBarPopoverView.size,
                                   to: "menubar-populated.png")
    #expect(bytes > 5000)
}

@MainActor @Test func renderEmpty() async throws {
    // Fresh install: no servers configured yet, nothing recorded.
    let viewModel = makeViewModel(messages: [], unread: 0, statuses: [])
    await viewModel.refresh()
    #expect(viewModel.filteredGroups.isEmpty)
    let bytes = try renderSnapshot(popoverView(viewModel), size: MenuBarPopoverView.size,
                                   to: "menubar-empty.png")
    #expect(bytes > 1000)
}

@MainActor @Test func renderDisconnected() async throws {
    let statuses = [
        MenuBarServerStatus(serverID: MenuBarFixtures.homeLabID, name: "Home Lab",
                            state: .backoff(attempt: 3)),
        MenuBarServerStatus(serverID: MenuBarFixtures.publicID, name: "ntfy.sh",
                            state: .degraded(reason: .rateLimited)),
    ]
    let viewModel = makeViewModel(messages: MenuBarFixtures.messages(), unread: 3, statuses: statuses)
    await viewModel.refresh()
    #expect(viewModel.connectivity == .disconnected)
    let bytes = try renderSnapshot(popoverView(viewModel), size: MenuBarPopoverView.size,
                                   to: "menubar-disconnected.png")
    #expect(bytes > 5000)
}

@MainActor @Test func renderLoadError() async throws {
    // Call 1 succeeds (establishes stale-but-valid data), call 2 fails.
    // `refresh()` on a failure must keep the stale data and only add the
    // error banner — never fall back to an empty list, which would read as
    // "no messages" (see `MenuBarViewModel.refresh()`'s comment).
    let viewModel = makeViewModel(messages: MenuBarFixtures.messages(), unread: 3,
                                  statuses: [MenuBarFixtures.homeLab, MenuBarFixtures.ntfySh],
                                  failFrom: 2)
    await viewModel.refresh()
    await viewModel.refresh()
    #expect(viewModel.loadErrorMessage != nil)
    #expect(!viewModel.groups.isEmpty)
    let bytes = try renderSnapshot(popoverView(viewModel), size: MenuBarPopoverView.size,
                                   to: "menubar-load-error.png")
    #expect(bytes > 5000)
}

@MainActor @Test func renderSearchActive() async throws {
    let viewModel = makeViewModel(messages: MenuBarFixtures.messages(), unread: 3,
                                  statuses: [MenuBarFixtures.homeLab, MenuBarFixtures.ntfySh])
    await viewModel.refresh()
    // Matches only the "backup verification failed" message's body.
    viewModel.searchText = "certificate"
    #expect(viewModel.filteredGroups.count == 1)
    #expect(viewModel.filteredGroups.first?.messages.count == 1)
    let bytes = try renderSnapshot(popoverView(viewModel), size: MenuBarPopoverView.size,
                                   to: "menubar-search-active.png")
    #expect(bytes > 3000)
}

@MainActor @Test func renderPopulatedDarkMode() async throws {
    let viewModel = makeViewModel(messages: MenuBarFixtures.messages(), unread: 3,
                                  statuses: [MenuBarFixtures.homeLab, MenuBarFixtures.ntfySh])
    await viewModel.refresh()
    let lightBytes = try renderSnapshot(popoverView(viewModel), size: MenuBarPopoverView.size,
                                        to: "menubar-populated.png")
    let darkBytes = try renderSnapshot(popoverView(viewModel), size: MenuBarPopoverView.size,
                                       colorScheme: .dark, to: "menubar-populated-dark.png")
    #expect(darkBytes > 5000)
    // A dark render byte-identical to the light one is the exact failure
    // mode `renderSnapshot`'s doc comment warns about: a render that
    // succeeds and shows nothing (or shows the same nothing twice).
    #expect(darkBytes != lightBytes)
}
