import AppKit
import SwiftData
import SwiftUI
import Testing
import NtfyKit
@testable import NtfyMe

/// Headless renders of the History window for visual review — this
/// repository is public, so every server name, topic, and message body
/// below is invented (never a real hostname, credential, or anything from
/// a real deployment).
///
/// Every render drives a real in-memory `ModelContainer` + `MessageStore` +
/// `HistoryViewModel`, not canned `MessageSnapshot` values — seeding needed
/// nothing beyond `NtfyKit`'s public `Server`/`Subscription`/`Message`/
/// `Attachment` initializers, so this exercises the actual query path
/// (`MessageStore.search`, `topicSummaries`, `servers`) the live app uses.
///
/// Renders go through `renderSnapshot` (`SnapshotSupport.swift`), not bare
/// `ImageRenderer`: this surface leans on `List`, `NavigationSplitView`,
/// `ScrollView`, and `.toolbar`, which is exactly the combination
/// `SnapshotSupport.swift`'s doc comment identifies as coming back blank or
/// as placeholder chrome under `ImageRenderer` alone — confirmed here by
/// inspecting actual pixel data, not assumed from a plausible file size: an
/// early pass produced a giant red-on-yellow glyph for the three-column
/// view and a solid black image for the detail pane.
@MainActor
private enum HistorySnapshotFixtures {
    static func inMemoryContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: Server.self, Subscription.self, Message.self, Attachment.self,
                                  configurations: config)
    }

    struct Populated {
        let store: MessageStore
        let homeLabID: UUID
        let ntfyShID: UUID
        let officeID: UUID
        let deployFailedID: String
        let alertsFirstUnreadID: String
        let longStressID: String
    }

    /// Three servers, several topics each, a mix of read/unread messages
    /// across priorities — plus one message with a markdown body, a link,
    /// tags, two actions, and an attachment (the "rich content" render), and
    /// one message with a very long title/body and a topic name long enough
    /// to need truncating in the sidebar (the "long-content stress" render).
    static func makePopulated() throws -> Populated {
        let container = try inMemoryContainer()
        let context = ModelContext(container)

        let homeLab = Server(name: "Home Lab", baseURLString: "https://ntfy.homelab.example", sortOrder: 0)
        let ntfySh = Server(name: "ntfy.sh", baseURLString: "https://ntfy.sh", sortOrder: 1)
        let office = Server(name: "Office", baseURLString: "https://ntfy.office.example", sortOrder: 2)
        [homeLab, ntfySh, office].forEach(context.insert)

        context.insert(Subscription(topic: "alerts", server: homeLab))
        context.insert(Subscription(topic: "backups", server: homeLab))
        context.insert(Subscription(topic: "deploys", displayName: "Deploys", server: homeLab, muted: true))
        context.insert(Subscription(
            topic: "infrastructure-monitoring-alerts-critical-notifications", server: homeLab))
        context.insert(Subscription(topic: "weather", server: ntfySh))
        context.insert(Subscription(topic: "uptime-kuma", server: ntfySh))
        context.insert(Subscription(topic: "printer-alerts", server: office))

        let now = Date()
        func minutesAgo(_ m: Double) -> Date { now.addingTimeInterval(-m * 60) }

        let a1 = Message(serverID: homeLab.id, topic: "alerts", messageID: "a1", time: minutesAgo(5),
                         title: "Disk space critical", body: "`/var` is at 96% on **db-01**.",
                         priority: 5, tags: ["rotating_light"], isRead: false)
        let a2 = Message(serverID: homeLab.id, topic: "alerts", messageID: "a2", time: minutesAgo(60),
                         title: "Service recovered", body: "**api-gateway** back to healthy.",
                         priority: 3, tags: ["white_check_mark"], isRead: true)
        let a3 = Message(serverID: homeLab.id, topic: "alerts", messageID: "a3", time: minutesAgo(180),
                         title: nil, body: "Latency spike detected on edge-02",
                         priority: 4, tags: ["warning", "edge"], isRead: false)
        [a1, a2, a3].forEach(context.insert)

        let b1 = Message(serverID: homeLab.id, topic: "backups", messageID: "b1", time: minutesAgo(8 * 60),
                         title: "Nightly backup complete", body: "247 GB written to offsite storage.",
                         priority: 2, tags: ["white_check_mark"], isRead: true)
        let b2 = Message(serverID: homeLab.id, topic: "backups", messageID: "b2", time: minutesAgo(32 * 60),
                         title: "Backup verification passed", body: "Checksum OK for the 2026-09-01 snapshot.",
                         priority: 2, isRead: true)
        [b1, b2].forEach(context.insert)

        let d1 = Message(serverID: homeLab.id, topic: "deploys", messageID: "d1", time: minutesAgo(20),
                         title: "Deploy started: web-03", body: "Rolling out v2.14.0.",
                         priority: 3, isRead: false)
        let deployAttachment = Attachment(name: "build-log.txt",
                                          urlString: "https://example.com/build/482/log.txt",
                                          type: "text/plain", size: 18_320, localFilename: "build-log.txt")
        let deployActionsJSON = Data(#"""
        [{"id":"act1","action":"view","label":"Open Dashboard","clear":false,"url":"https://example.com/build/482"},
         {"id":"act2","action":"copy","label":"Copy Build ID","clear":false,"value":"482"}]
        """#.utf8)
        let d2 = Message(serverID: homeLab.id, topic: "deploys", messageID: "d2", time: minutesAgo(15),
                         title: "Deploy failed: web-03",
                         body: """
                         **Build #482** failed on `web-03`.

                         See the [dashboard](https://example.com/build/482) for full logs.

                         - Exit code: 137
                         - Duration: 4m12s
                         """,
                         priority: 5, tags: ["rotating_light", "fire", "web-03"],
                         click: "https://example.com/build/482", contentType: "text/markdown",
                         actionsJSON: deployActionsJSON, attachment: deployAttachment, isRead: false)
        [d1, d2].forEach(context.insert)

        let longBody = Array(repeating: """
            This alert repeats the same sentence many times so the detail pane's \
            body has to wrap across a large number of lines and the list row's \
            preview has to truncate instead of overflowing the window.
            """, count: 6).joined(separator: " ")
        let stress = Message(
            serverID: homeLab.id,
            topic: "infrastructure-monitoring-alerts-critical-notifications",
            messageID: "s1", time: minutesAgo(2),
            title: "Extremely Long Alert Title That Should Truncate Or Wrap Depending On Column Width",
            body: longBody, priority: 5,
            tags: ["a-very-long-tag-name-for-wrap-testing", "urgent", "p1"], isRead: false)
        context.insert(stress)

        let w1 = Message(serverID: ntfySh.id, topic: "weather", messageID: "w1", time: minutesAgo(40),
                         title: "Storm Warning", body: "Severe thunderstorm expected 6-9pm.",
                         priority: 4, tags: ["warning", "weather"], isRead: false)
        let w2 = Message(serverID: ntfySh.id, topic: "weather", messageID: "w2",
                         time: minutesAgo(2 * 24 * 60),
                         title: "Forecast updated", body: "Sunny skies through the weekend.",
                         priority: 1, isRead: true)
        [w1, w2].forEach(context.insert)

        let u1 = Message(serverID: ntfySh.id, topic: "uptime-kuma", messageID: "u1", time: minutesAgo(10 * 60),
                         title: "All monitors healthy", body: "12/12 services up.",
                         priority: 2, isRead: true)
        context.insert(u1)

        let o1 = Message(serverID: office.id, topic: "printer-alerts", messageID: "o1", time: minutesAgo(500),
                         title: "Printer offline", body: "3rd floor printer is unreachable.",
                         priority: 2, isRead: true)
        context.insert(o1)

        try context.save()

        return Populated(
            store: MessageStore(modelContainer: container),
            homeLabID: homeLab.id, ntfyShID: ntfySh.id, officeID: office.id,
            deployFailedID: d2.uniqueKey, alertsFirstUnreadID: a1.uniqueKey, longStressID: stress.uniqueKey)
    }

    /// No servers, no topics, no messages at all.
    static func makeEmpty() throws -> MessageStore {
        MessageStore(modelContainer: try inMemoryContainer())
    }
}

/// `NavigationSplitView`'s **sidebar column specifically** does not draw
/// through `renderSnapshot`'s offscreen `cacheDisplay` path, regardless of
/// what is inside it — reproduced down to a bare `NavigationSplitView` with a
/// plain `VStack { Text(...) }` as the sidebar (no `List`, no vibrancy
/// material, nothing History-specific), and not fixed by ordering the window
/// onto a real backing store first or spinning the run loop before capture.
/// The `content`/`detail` columns of the same `NavigationSplitView` render
/// correctly; only the sidebar slot comes back blank. This looks like a
/// harness limitation specific to `NavigationSplitView`'s sidebar chrome, not
/// a product bug — `HistorySidebarView` renders perfectly when captured on
/// its own (`historySidebarStatusDots` below), which is why every composite
/// render still exists: list and detail content, and column proportions, are
/// still honestly represented, only the sidebar's own content is not visible
/// in those composite files. Reported to the team lead rather than chased
/// further inside this file.

@MainActor
@Test func historyPopulatedThreeColumns() async throws {
    let fixture = try HistorySnapshotFixtures.makePopulated()
    let viewModel = HistoryViewModel(store: fixture.store)
    await viewModel.loadSidebar()
    viewModel.scope = .topic(serverID: fixture.homeLabID, topic: "alerts")
    await viewModel.refreshMessages()
    viewModel.selection = [fixture.alertsFirstUnreadID]

    let bytes = try renderSnapshot(HistoryView(viewModel: viewModel),
                                   size: CGSize(width: 900, height: 560), to: "history-populated.png")
    #expect(bytes > 1000)
}

/// The detail pane alone, tall enough that nothing in it is clipped by a
/// fixed 560pt window height — the point of this render is the content
/// itself (markdown, link, tags, two actions, an attachment), not window
/// proportions, which `historyPopulatedThreeColumns` already covers.
@MainActor
@Test func historyDetailRichContent() async throws {
    let fixture = try HistorySnapshotFixtures.makePopulated()
    let viewModel = HistoryViewModel(store: fixture.store, attachmentsDirectory: FileManager.default.temporaryDirectory)
    await viewModel.loadSidebar()
    viewModel.scope = .topic(serverID: fixture.homeLabID, topic: "deploys")
    await viewModel.refreshMessages()
    viewModel.selection = [fixture.deployFailedID]

    let bytes = try renderSnapshot(HistoryDetailView(viewModel: viewModel),
                                   size: CGSize(width: 420, height: 900), to: "history-detail-rich.png")
    #expect(bytes > 1000)
}

@MainActor
@Test func historyEmpty() async throws {
    let store = try HistorySnapshotFixtures.makeEmpty()
    let viewModel = HistoryViewModel(store: store)
    await viewModel.loadSidebar()
    await viewModel.refreshMessages()

    let bytes = try renderSnapshot(HistoryView(viewModel: viewModel),
                                   size: CGSize(width: 900, height: 560), to: "history-empty.png")
    #expect(bytes > 1000)
}

@MainActor
@Test func historyNoSelection() async throws {
    let fixture = try HistorySnapshotFixtures.makePopulated()
    let viewModel = HistoryViewModel(store: fixture.store)
    await viewModel.loadSidebar()
    viewModel.scope = .topic(serverID: fixture.homeLabID, topic: "alerts")
    await viewModel.refreshMessages()
    // Selection intentionally left empty: a topic with messages is picked,
    // but no message within it is, so the detail pane's placeholder shows.

    let bytes = try renderSnapshot(HistoryView(viewModel: viewModel),
                                   size: CGSize(width: 900, height: 560), to: "history-no-selection.png")
    #expect(bytes > 1000)
}

/// Sidebar alone, at a size that fits it without the list/detail columns
/// diluting the thing this render exists to check: the three status dots
/// read as visually distinct.
@MainActor
@Test func historySidebarStatusDots() async throws {
    let fixture = try HistorySnapshotFixtures.makePopulated()
    let viewModel = HistoryViewModel(store: fixture.store)
    await viewModel.loadSidebar()
    viewModel.statusProvider = { serverID in
        switch serverID {
        case fixture.homeLabID: return .connected
        case fixture.ntfyShID: return .connecting
        case fixture.officeID: return .disconnected
        default: return .unknown
        }
    }

    let bytes = try renderSnapshot(HistorySidebarView(viewModel: viewModel),
                                   size: CGSize(width: 240, height: 420), to: "history-sidebar-status.png")
    #expect(bytes > 1000)
}

@MainActor
@Test func historyPopulatedDarkMode() async throws {
    let fixture = try HistorySnapshotFixtures.makePopulated()
    let viewModel = HistoryViewModel(store: fixture.store)
    await viewModel.loadSidebar()
    viewModel.scope = .topic(serverID: fixture.homeLabID, topic: "alerts")
    await viewModel.refreshMessages()
    viewModel.selection = [fixture.alertsFirstUnreadID]

    let bytes = try renderSnapshot(HistoryView(viewModel: viewModel), size: CGSize(width: 900, height: 560),
                                   colorScheme: .dark, to: "history-populated-dark.png")
    #expect(bytes > 1000)
}

@MainActor
@Test func historyLongContentStress() async throws {
    let fixture = try HistorySnapshotFixtures.makePopulated()
    let viewModel = HistoryViewModel(store: fixture.store)
    await viewModel.loadSidebar()
    viewModel.scope = .topic(
        serverID: fixture.homeLabID, topic: "infrastructure-monitoring-alerts-critical-notifications")
    await viewModel.refreshMessages()
    viewModel.selection = [fixture.longStressID]

    let bytes = try renderSnapshot(HistoryView(viewModel: viewModel),
                                   size: CGSize(width: 900, height: 560), to: "history-long-content.png")
    #expect(bytes > 1000)
}
