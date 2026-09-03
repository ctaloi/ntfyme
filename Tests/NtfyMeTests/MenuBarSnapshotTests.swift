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
/// a human to look at — but each render is also asserted on with
/// `distinctColorCount`, not a byte-count floor: a blank render at this
/// popover's size is ~14KB, above every floor this file used to have, so a
/// byte assertion could not fail on the exact "no background" regression
/// these renders exist to catch (`SnapshotSupport.swift` has the
/// measurements). See `backgroundRegressionIsCaught()` below for the
/// mutation check confirming the new assertion actually fails on it.
///
/// A light/dark **divergence** check (`lightBytes != darkBytes`, or a
/// threshold on `|light − dark|`) was tried here too and removed: measured
/// against this exact regression at the popover's real size, the buggy
/// render (104,752 / 118,459 bytes) diverges *more* than the fixed one
/// (120,869 / 122,953) — the ordering a divergence check relies on is
/// inverted, so no threshold on the difference distinguishes them. Every
/// render below is asserted on its own `distinctColorCount` instead, which
/// is monotonic the right way on the same regression: blank 1, broken 1-2,
/// fixed 25-29.
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

/// A mutable flag a `@Sendable` closure can capture and a test can flip
/// mid-run. A plain captured `var` is not permitted here — Swift 6 strict
/// concurrency rejects mutable-var capture in a `@Sendable` closure — so
/// this is a class for the same reason `MenuBarFixtureCallCounter` above is
/// one: only ever touched serially, on the main actor, by the one
/// `MenuBarViewModel` under test.
final class MenuBarFixtureFlag: @unchecked Sendable {
    var value = false
}

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

/// Below a blank render's own colour count (1, per `SnapshotSupport`'s
/// measurement) with a wide margin, and comfortably below every real render
/// this file produces (dozens at minimum, even for the sparsest state) —
/// wide enough to not be sensitive to small copy or layout changes, while
/// still failing outright on a render that drew nothing.
private let minimumDistinctColors = 8

/// A view that paints its own ground measures ~1.0; a root with no
/// background measures ~0.05 (`SnapshotSupport.meanAlpha`'s own
/// calibration). 0.85 clears every real render here with room and is the
/// one instrument that catches this regression directly — byte counts,
/// light/dark divergence, and colour counts all fail on it in one way or
/// another (see the doc comments above and on `meanAlpha` itself).
private let minimumOpacity = 0.85

@MainActor @Test(requiresSnapshotRendering) func renderPopulated() async throws {
    let viewModel = makeViewModel(messages: MenuBarFixtures.messages(), unread: 3,
                                  statuses: [MenuBarFixtures.homeLab, MenuBarFixtures.ntfySh])
    await viewModel.refresh()
    #expect(!viewModel.filteredGroups.isEmpty)
    _ = try renderSnapshot(popoverView(viewModel), size: MenuBarPopoverView.size,
                           to: "menubar-populated.png")
    let colors = try distinctColorCount(ofPNGAt: "/tmp/ntfyshots/menubar-populated.png")
    #expect(colors > minimumDistinctColors)
    #expect(try meanAlpha(ofPNGAt: "/tmp/ntfyshots/menubar-populated.png") > minimumOpacity)
}

@MainActor @Test(requiresSnapshotRendering) func renderEmpty() async throws {
    // Fresh install: no servers configured yet, nothing recorded. Still has
    // real chrome (header, empty-state icon and copy, footer), so this is
    // not expected to be anywhere near a blank render's colour count.
    let viewModel = makeViewModel(messages: [], unread: 0, statuses: [])
    await viewModel.refresh()
    #expect(viewModel.filteredGroups.isEmpty)
    _ = try renderSnapshot(popoverView(viewModel), size: MenuBarPopoverView.size,
                           to: "menubar-empty.png")
    let colors = try distinctColorCount(ofPNGAt: "/tmp/ntfyshots/menubar-empty.png")
    #expect(colors > minimumDistinctColors)
    #expect(try meanAlpha(ofPNGAt: "/tmp/ntfyshots/menubar-empty.png") > minimumOpacity)
}

@MainActor @Test(requiresSnapshotRendering) func renderDisconnected() async throws {
    let statuses = [
        MenuBarServerStatus(serverID: MenuBarFixtures.homeLabID, name: "Home Lab",
                            state: .backoff(attempt: 3)),
        MenuBarServerStatus(serverID: MenuBarFixtures.publicID, name: "ntfy.sh",
                            state: .degraded(reason: .rateLimited)),
    ]
    let viewModel = makeViewModel(messages: MenuBarFixtures.messages(), unread: 3, statuses: statuses)
    await viewModel.refresh()
    #expect(viewModel.connectivity == .disconnected)
    _ = try renderSnapshot(popoverView(viewModel), size: MenuBarPopoverView.size,
                           to: "menubar-disconnected.png")
    let colors = try distinctColorCount(ofPNGAt: "/tmp/ntfyshots/menubar-disconnected.png")
    #expect(colors > minimumDistinctColors)
    #expect(try meanAlpha(ofPNGAt: "/tmp/ntfyshots/menubar-disconnected.png") > minimumOpacity)
}

@MainActor @Test(requiresSnapshotRendering) func renderLoadError() async throws {
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
    _ = try renderSnapshot(popoverView(viewModel), size: MenuBarPopoverView.size,
                           to: "menubar-load-error.png")
    let colors = try distinctColorCount(ofPNGAt: "/tmp/ntfyshots/menubar-load-error.png")
    #expect(colors > minimumDistinctColors)
    #expect(try meanAlpha(ofPNGAt: "/tmp/ntfyshots/menubar-load-error.png") > minimumOpacity)
}

/// Behavioral, not visual: `connectionStatuses` returning `nil` (the store
/// failed to open) must not read as `.noServers` — "no servers configured",
/// the fresh-install empty state. That collapse is exactly the bug this
/// pins: telling a user whose archive failed to open that they have not set
/// anything up yet, which invites them to add a server that will not help.
/// `refresh()` must keep the last-known `serverStatuses` and surface
/// `loadErrorMessage` instead, the same stale-data-plus-banner treatment
/// `renderLoadError` above already covers for the messages path.
@MainActor @Test func connectionStatusFailureKeepsStaleStatuses() async throws {
    let shouldFail = MenuBarFixtureFlag()
    let dependencies = MenuBarViewModel.Dependencies(
        recentMessages: { [] },
        unreadCount: { 0 },
        connectionStatuses: {
            shouldFail.value ? nil : [MenuBarFixtures.homeLab, MenuBarFixtures.ntfySh]
        },
        markRead: { _, _ in },
        markAllRead: {})
    let viewModel = MenuBarViewModel(dependencies: dependencies)

    await viewModel.refresh()
    #expect(viewModel.connectivity == .allConnected)
    #expect(viewModel.loadErrorMessage == nil)

    shouldFail.value = true
    await viewModel.refresh()
    #expect(viewModel.serverStatuses == [MenuBarFixtures.homeLab, MenuBarFixtures.ntfySh])
    #expect(viewModel.connectivity == .allConnected)
    #expect(viewModel.connectivity != .noServers)
    #expect(viewModel.loadErrorMessage != nil)
}

@MainActor @Test(requiresSnapshotRendering) func renderSearchActive() async throws {
    let viewModel = makeViewModel(messages: MenuBarFixtures.messages(), unread: 3,
                                  statuses: [MenuBarFixtures.homeLab, MenuBarFixtures.ntfySh])
    await viewModel.refresh()
    // Matches only the "backup verification failed" message's body.
    viewModel.searchText = "certificate"
    #expect(viewModel.filteredGroups.count == 1)
    #expect(viewModel.filteredGroups.first?.messages.count == 1)
    _ = try renderSnapshot(popoverView(viewModel), size: MenuBarPopoverView.size,
                           to: "menubar-search-active.png")
    let colors = try distinctColorCount(ofPNGAt: "/tmp/ntfyshots/menubar-search-active.png")
    #expect(colors > minimumDistinctColors)
    #expect(try meanAlpha(ofPNGAt: "/tmp/ntfyshots/menubar-search-active.png") > minimumOpacity)
}

/// Dark-mode-only: `renderPopulated()` above already covers the light
/// render (and its own `distinctColorCount` floor), including writing
/// `menubar-populated.png`. This used to re-render that same light copy
/// here too, under the same filename — harmless while assertions read the
/// in-memory byte count, but a real hazard once `distinctColorCount` reads
/// the file back off disk: `renderPopulated()` and this test run in
/// parallel, so two writers to one filename risked a torn read, not just a
/// torn artifact (`renderSnapshot`'s own doc comment now covers the
/// atomic-write half of this; a unique filename per test is the other
/// half). Dropped the redundant light render entirely rather than giving it
/// a second unique filename — nothing here needed it.
@MainActor @Test(requiresSnapshotRendering) func renderPopulatedDarkMode() async throws {
    let viewModel = makeViewModel(messages: MenuBarFixtures.messages(), unread: 3,
                                  statuses: [MenuBarFixtures.homeLab, MenuBarFixtures.ntfySh])
    await viewModel.refresh()
    _ = try renderSnapshot(popoverView(viewModel), size: MenuBarPopoverView.size,
                           colorScheme: .dark, to: "menubar-populated-dark.png")
    let colors = try distinctColorCount(ofPNGAt: "/tmp/ntfyshots/menubar-populated-dark.png")
    #expect(colors > minimumDistinctColors)
    #expect(try meanAlpha(ofPNGAt: "/tmp/ntfyshots/menubar-populated-dark.png") > minimumOpacity)
}

/// Mutation check for the assertions above: reproduce the bug's shape and
/// confirm the *assertion*, not just the fixture, actually fails on it.
/// Renders a standalone view with the background deliberately omitted,
/// rather than editing `MenuBarPopoverView.swift` itself, since a mutation
/// test's job is to prove the check fails on the bug, not to reintroduce it.
/// Uses `distinctColorCount`, the same assertion every render above uses,
/// per the team's guidance to standardize on it rather than maintain a
/// second luminance-based check with its own separately-calibrated
/// thresholds — one measurement the whole project trusts, not two.
///
/// This test's own first draft tried wrapping `MenuBarPopoverView` from the
/// outside with its background "removed". That proved nothing: a
/// `.background(...)` applied inside a view's own `body` cannot be stripped
/// by whatever wraps it, so the wrapped render was silently the
/// already-fixed view and the mutation check passed for the wrong reason.
/// This version reproduces the bug's actual shape — dynamic-color text with
/// no background behind it — as a standalone view that never had the fix,
/// the only way to actually exercise the broken code path.
@MainActor @Test(requiresSnapshotRendering) func backgroundRegressionIsCaught() throws {
    struct BrokenReproduction: View {
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text("NtfyMe").font(.headline)
                Text("Connected").font(.caption).foregroundStyle(.secondary)
                Divider()
                Text("Disk usage high").fontWeight(.semibold)
                Text("Root partition on nas01 is at 92% capacity.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(width: MenuBarPopoverView.size.width, height: MenuBarPopoverView.size.height)
            // Deliberately no `.background(...)` — this is the bug as it
            // shipped in `MenuBarPopoverView` before that fix.
        }
    }

    _ = try renderSnapshot(BrokenReproduction(), size: MenuBarPopoverView.size,
                           colorScheme: .dark, to: "menubar-mutation-no-background-dark.png")
    let colors = try distinctColorCount(
        ofPNGAt: "/tmp/ntfyshots/menubar-mutation-no-background-dark.png")
    // Below the same floor every real render above must clear — proving
    // this specific regression's shape actually fails `distinctColorCount`,
    // not just that some blank image somewhere would.
    #expect(colors < minimumDistinctColors)

    // The direct instrument for this exact bug shape: a root with no
    // background measures ~0.05 alpha (`meanAlpha`'s own calibration),
    // comfortably below the 0.85 floor every real render above must clear.
    let alpha = try meanAlpha(
        ofPNGAt: "/tmp/ntfyshots/menubar-mutation-no-background-dark.png")
    #expect(alpha < minimumOpacity)
}
