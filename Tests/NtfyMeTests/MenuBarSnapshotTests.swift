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
/// `distinctColorCount`/`meanLuminance`, not a byte-count floor: a blank
/// render at this popover's size is ~14KB, above every floor this file used
/// to have, so a byte assertion could not fail on the exact "no background"
/// regression these renders exist to catch (`SnapshotSupport.swift` has the
/// measurements). See `backgroundRegressionIsCaught()` below for the
/// mutation check confirming the new assertion actually fails on it.
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

/// Below a blank render's own colour count (1, per `SnapshotSupport`'s
/// measurement) with a wide margin, and comfortably below every real render
/// this file produces (dozens at minimum, even for the sparsest state) —
/// wide enough to not be sensitive to small copy or layout changes, while
/// still failing outright on a render that drew nothing.
private let minimumDistinctColors = 8

@MainActor @Test func renderPopulated() async throws {
    let viewModel = makeViewModel(messages: MenuBarFixtures.messages(), unread: 3,
                                  statuses: [MenuBarFixtures.homeLab, MenuBarFixtures.ntfySh])
    await viewModel.refresh()
    #expect(!viewModel.filteredGroups.isEmpty)
    _ = try renderSnapshot(popoverView(viewModel), size: MenuBarPopoverView.size,
                           to: "menubar-populated.png")
    let colors = try distinctColorCount(ofPNGAt: "/tmp/ntfyshots/menubar-populated.png")
    #expect(colors > minimumDistinctColors)
}

@MainActor @Test func renderEmpty() async throws {
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
    _ = try renderSnapshot(popoverView(viewModel), size: MenuBarPopoverView.size,
                           to: "menubar-disconnected.png")
    let colors = try distinctColorCount(ofPNGAt: "/tmp/ntfyshots/menubar-disconnected.png")
    #expect(colors > minimumDistinctColors)
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
    _ = try renderSnapshot(popoverView(viewModel), size: MenuBarPopoverView.size,
                           to: "menubar-load-error.png")
    let colors = try distinctColorCount(ofPNGAt: "/tmp/ntfyshots/menubar-load-error.png")
    #expect(colors > minimumDistinctColors)
}

@MainActor @Test func renderSearchActive() async throws {
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
}

/// `SnapshotSupport.swift`'s own measurement of this exact regression
/// (broken 1-2 colours, fixed 25-29, blank 1) means `distinctColorCount`
/// alone would already have caught it — but `meanLuminance` is kept as a
/// second, more direct signal: it asserts the actual thing that matters
/// ("light render reads as light, dark render reads as dark"), rather than
/// inferring correctness from a colour count that happens to move together
/// with it today. `backgroundRegressionIsCaught()` below confirms both on
/// this machine rather than trusting either measurement on faith.
@MainActor @Test func renderPopulatedDarkMode() async throws {
    let viewModel = makeViewModel(messages: MenuBarFixtures.messages(), unread: 3,
                                  statuses: [MenuBarFixtures.homeLab, MenuBarFixtures.ntfySh])
    await viewModel.refresh()
    _ = try renderSnapshot(popoverView(viewModel), size: MenuBarPopoverView.size,
                           to: "menubar-populated.png")
    _ = try renderSnapshot(popoverView(viewModel), size: MenuBarPopoverView.size,
                           colorScheme: .dark, to: "menubar-populated-dark.png")

    let lightColors = try distinctColorCount(ofPNGAt: "/tmp/ntfyshots/menubar-populated.png")
    let darkColors = try distinctColorCount(ofPNGAt: "/tmp/ntfyshots/menubar-populated-dark.png")
    #expect(lightColors > minimumDistinctColors)
    #expect(darkColors > minimumDistinctColors)

    let lightLuminance = try meanLuminance(ofPNGAt: "/tmp/ntfyshots/menubar-populated.png")
    let darkLuminance = try meanLuminance(ofPNGAt: "/tmp/ntfyshots/menubar-populated-dark.png")
    #expect(lightLuminance > 0.6)
    #expect(darkLuminance < 0.4)
}

/// Mutation check for the assertions above: reproduce the bug's shape and
/// confirm the *assertion*, not just the fixture, actually fails on it.
/// Renders a standalone view with the background deliberately omitted,
/// rather than editing `MenuBarPopoverView.swift` itself, since a mutation
/// test's job is to prove the check fails on the bug, not to reintroduce it.
///
/// Two things this test's own first draft got wrong, both worth recording:
///
/// 1. It first tried wrapping `MenuBarPopoverView` from the outside with its
///    background "removed". That proved nothing: a `.background(...)`
///    applied inside a view's own `body` cannot be stripped by whatever
///    wraps it, so the wrapped render was silently the already-fixed view.
///    This version reproduces the bug's actual shape — dynamic-color text
///    with no background behind it — as a standalone view that never had
///    the fix, the only way to actually exercise the broken code path.
/// 2. It assumed the broken render would read as *bright* under `.dark`
///    (light text on nothing), by analogy with the original `ImageRenderer`
///    finding. Measured here, it does not: `cacheDisplay(in:to:)` captures
///    only what the hosting view itself paints, so an unpainted region reads
///    back as literal black through `NSBitmapImageRep.colorAt`, not as
///    "whatever happens to show through". The result is a render that
///    reads as *near-black* (0.016 measured), not bright — nearly 10x
///    darker than a properly-backgrounded dark render (0.150, measured in
///    `renderPopulatedDarkMode` above) rather than lighter. Both are wrong;
///    they are wrong in opposite directions depending on capture technique,
///    which is exactly why this mutation check exists instead of trusting
///    the earlier finding by analogy.
@MainActor @Test func backgroundRegressionIsCaught() throws {
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
    let luminance = try meanLuminance(
        ofPNGAt: "/tmp/ntfyshots/menubar-mutation-no-background-dark.png")
    // Below 0.05: comfortably under the real fixed dark render's own 0.150,
    // and far enough from it that this cannot be mistaken for "also
    // correctly dark". A properly-backgrounded dark popover has a real
    // opaque mid-dark fill behind mostly-light text; this has almost none
    // of that fill contributing anything at all.
    #expect(luminance < 0.05)
}
