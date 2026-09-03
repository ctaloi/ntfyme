import SwiftUI
import Testing
@testable import NtfyMe

// MOCKUPS FOR APPROVAL — not production code, not wired to anything.
// Static content only, so the layout can be judged before it is built.

private struct MockRow: Identifiable {
    let id = UUID()
    let title: String
    let body: String
    let time: String
    let unread: Bool
    let priority: Int
    let topic: String
}

private let mockRows = [
    MockRow(title: "Disk space critical", body: "/var is at 96% on db-01. Cleanup job did not run.",
            time: "7:45 PM", unread: true, priority: 5, topic: "alerts"),
    MockRow(title: "Deploy finished", body: "Build #482 deployed to production in 3m12s.",
            time: "6:50 PM", unread: false, priority: 3, topic: "deploys"),
    MockRow(title: "Backup verification failed", body: "Monthly restore-test for the certificate archive failed checksum.",
            time: "4:12 PM", unread: true, priority: 4, topic: "backups"),
    MockRow(title: "Service recovered", body: "api-gateway back to healthy after 4 minutes.",
            time: "2:03 PM", unread: false, priority: 2, topic: "alerts"),
    MockRow(title: "Weekly summary", body: "12 jobs completed, 0 failures.",
            time: "Yesterday", unread: false, priority: 1, topic: "backups"),
]

private func priorityColor(_ p: Int) -> Color {
    switch p {
    case 5: return .red
    case 4: return .orange
    case 1, 2: return .secondary
    default: return .secondary
    }
}

// MARK: - Sidebar

private struct MockSidebar: View {
    var body: some View {
        List {
            Section {
                Label("All Messages", systemImage: "tray.full")
                    .badge(3)
                Label("Unread", systemImage: "circle.inset.filled")
                    .badge(3)
            }
            Section("Home Lab") {
                topic("alerts", 2, muted: false)
                topic("deploys", 0, muted: false)
                topic("backups", 1, muted: false)
            }
            Section("ntfy.sh") {
                topic("server-alerts", 0, muted: false)
                topic("smoke-test", 0, muted: true)
            }
        }
        .listStyle(.sidebar)
        .frame(width: 215)
    }

    private func topic(_ name: String, _ count: Int, muted: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "number")
                .foregroundStyle(.secondary)
                .font(.system(size: 11, weight: .semibold))
            Text(name).lineLimit(1)
            if muted {
                Image(systemName: "bell.slash.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if count > 0 {
                Text("\(count)").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Message list

private struct MockList: View {
    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(Array(mockRows.enumerated()), id: \.element.id) { index, row in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(row.unread ? Color.accentColor : .clear)
                            .frame(width: 7, height: 7)
                            .padding(.top, 5)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(row.title)
                                    .font(.system(size: 13, weight: row.unread ? .semibold : .regular))
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Text(row.time)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Text(row.body)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 5) {
                                Text(row.topic)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.secondary)
                                if row.priority >= 4 {
                                    Image(systemName: "exclamationmark.2")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(priorityColor(row.priority))
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(index == 0 ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.25) : Color.clear)
                }
            }
            .listStyle(.inset)
        }
        .frame(width: 320)
    }
}

// MARK: - Detail

private struct MockDetail: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Disk space critical")
                    .font(.system(size: 22, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    Text("alerts").font(.system(size: 11, weight: .medium))
                    Text("·").foregroundStyle(.tertiary)
                    Text("Home Lab").font(.system(size: 11))
                    Text("·").foregroundStyle(.tertiary)
                    Text("Today at 7:45 PM").font(.system(size: 11))
                    Spacer()
                    Image(systemName: "exclamationmark.2")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.red)
                }
                .foregroundStyle(.secondary)

                Divider()

                Text("`/var` is at 96% on **db-01**. The nightly cleanup job did not run — its last successful pass was four days ago.")
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    ForEach(["rotating_light", "disk", "db-01"], id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: 11))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(Color(nsColor: .quaternaryLabelColor).opacity(0.35)))
                    }
                }

                HStack(spacing: 8) {
                    Button("Open Dashboard") {}
                    Button("Acknowledge") {}
                    Spacer()
                }
                .controlSize(.regular)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

// MARK: - Whole window

private struct MockWindow: View {
    var body: some View {
        VStack(spacing: 0) {
            // Toolbar: ONE grouped filter control, mark-all-read, and search.
            // Replaces three loose capsules plus a raw text field.
            HStack(spacing: 10) {
                Image(systemName: "sidebar.leading").foregroundStyle(.secondary)
                Divider().frame(height: 16)
                Label("Filter", systemImage: "line.3.horizontal.decrease")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 12))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Label("Mark All Read", systemImage: "envelope.open")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 12))
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11))
                    Text("Search").font(.system(size: 12))
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7).padding(.vertical, 4)
                .frame(width: 190)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.25)))
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            HStack(spacing: 0) {
                MockSidebar()
                Divider()
                MockList()
                Divider()
                MockDetail()
            }
        }
        .frame(width: 1000, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

@MainActor @Test(requiresSnapshotRendering) func mockupMainWindowLight() throws {
    _ = try renderSnapshot(MockWindow(), size: CGSize(width: 1000, height: 620),
                           colorScheme: .light, to: "redesign-main-light.png")
}

@MainActor @Test(requiresSnapshotRendering) func mockupMainWindowDark() throws {
    _ = try renderSnapshot(MockWindow(), size: CGSize(width: 1000, height: 620),
                           colorScheme: .dark, to: "redesign-main-dark.png")
}
