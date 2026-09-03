import SwiftUI
import NtfyKit

/// The History window's root view: a three-column `NavigationSplitView` —
/// sidebar (scope), list (search + filters), detail (selected message).
///
/// **The toolbar lives here, not on a column.** It used to be declared on
/// `HistoryListView` as a single `ToolbarItemGroup` with default placement,
/// which produced three reported symptoms, all of them the same mistake:
///
/// - *Icons moved when the sidebar was collapsed.* Default placement inside
///   a column is resolved relative to that column's own leading edge, and
///   collapsing the sidebar moves it. A toolbar belongs to the window, so
///   its items have to be declared where the window is.
/// - *"Icon Only" and "Text Only" broke the layout.* A `ToolbarItemGroup`
///   with no per-item `id` becomes one merged toolbar item rather than
///   several, so the display-mode menu had nothing individually labelled to
///   re-render. Each action is now its own `ToolbarItem(id:)` carrying a
///   `Label` with both a title and a symbol — which is exactly what
///   `NSToolbar` needs to draw any of the three display modes, and what
///   makes the items individually removable in Customize Toolbar.
/// - *The search field sat among the buttons.* `.searchable` is also
///   declared here now, so AppKit places it as the window's standard
///   trailing search field.
///
/// The filter popover's state lives here for the same reason: it is anchored
/// to a toolbar item, and the item is here.
struct HistoryView: View {
    @Bindable var viewModel: HistoryViewModel

    @State private var dateRangePopoverShown = false
    @State private var customSince: Date = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var customUntil: Date = Date()

    var body: some View {
        NavigationSplitView {
            HistorySidebarView(viewModel: viewModel)
        } content: {
            HistoryListView(viewModel: viewModel)
        } detail: {
            HistoryDetailView(viewModel: viewModel)
        }
        .navigationSplitViewStyle(.balanced)
        .searchable(text: $viewModel.searchText, placement: .toolbar,
                    prompt: "Search title or body")
        .toolbar(id: "history") {
            // `.primaryAction` rather than `.automatic`: window-relative, so
            // these do not move when a column does. Stable `id`s are what
            // let AppKit remember a customized toolbar across launches —
            // they must not be renamed once shipped.
            ToolbarItem(id: "filter", placement: .primaryAction) {
                filterMenu
            }
            ToolbarItem(id: "markAllRead", placement: .primaryAction) {
                markAllReadButton
            }
        }
    }

    /// One menu holding all four filter dimensions (unread, priority, tag,
    /// date range) — the approved redesign
    /// (`Tests/NtfyMeTests/RedesignMockups.swift`) replaced three loose
    /// toolbar capsules plus a raw tag `TextField` with this, because two
    /// competing text fields next to `.searchable`'s own was the single
    /// biggest reason the window did not read as a Mac app.
    private var filterMenu: some View {
        Menu {
            Toggle(isOn: $viewModel.unreadOnly) {
                Label("Unread Only", systemImage: "circle.inset.filled")
            }

            Menu {
                Picker("Priority", selection: $viewModel.priorityFilter) {
                    ForEach(PriorityFilter.allCases) { filter in
                        Text(filter.label).tag(filter)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Priority: \(viewModel.priorityFilter.label)", systemImage: "flag")
            }

            Menu {
                Button("Any Time") { viewModel.dateRangeFilter = .any }
                Button("Today") { viewModel.dateRangeFilter = .today }
                Button("Last 7 Days") { viewModel.dateRangeFilter = .last7Days }
                Button("Last 30 Days") { viewModel.dateRangeFilter = .last30Days }
                Divider()
                Button("Custom Range…") { dateRangePopoverShown = true }
            } label: {
                Label("Date: \(viewModel.dateRangeFilter.label)", systemImage: "calendar")
            }

            Divider()

            TextField("Tag", text: $viewModel.tagFilter)
                .accessibilityLabel(Text("Filter by tag"))
        } label: {
            // The title is not decoration: in "Text Only" it is the entire
            // item, and in Customize Toolbar it is how the item is named.
            // The symbol changes to its filled variant when a filter is
            // active — the one state this control has that is worth seeing
            // without opening it.
            Label("Filter", systemImage: viewModel.hasActiveFilters
                  ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
        }
        .help("Filter messages")
        .accessibilityLabel(Text(viewModel.hasActiveFilters ? "Filter (active)" : "Filter"))
        // Attached to the menu rather than nested inside it: a `Menu`
        // presenting a `.popover` from one of its own items works, but
        // anchoring the popover at the toolbar control itself (not the
        // transient menu item) is what keeps it from disappearing the
        // instant the menu that spawned it closes.
        .popover(isPresented: $dateRangePopoverShown) {
            VStack(alignment: .leading, spacing: 12) {
                DatePicker("From", selection: $customSince, displayedComponents: .date)
                DatePicker("To", selection: $customUntil, displayedComponents: .date)
                Button("Apply") {
                    viewModel.dateRangeFilter = .custom(since: customSince, until: customUntil)
                    dateRangePopoverShown = false
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
            .frame(width: 220)
        }
    }

    private var markAllReadButton: some View {
        Button {
            Task { await viewModel.markAllRead(serverID: viewModel.scope.serverID,
                                               topic: viewModel.scope.topic) }
        } label: {
            Label("Mark All Read", systemImage: "envelope.open")
        }
        .help("Mark All Read")
    }
}
