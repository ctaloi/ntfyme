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
    /// Opens the Compose window. Injected rather than reached for: this view
    /// knows nothing about `AppDelegate`, and the snapshot tests render it
    /// with no app around it at all.
    var onNewMessage: () -> Void = {}

    /// Driven by this view's own sidebar toggle rather than left to the
    /// automatic one — see `sidebarToggleButton`.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var dateRangePopoverShown = false
    @State private var customSince: Date = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var customUntil: Date = Date()

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            HistorySidebarView(viewModel: viewModel)
        } content: {
            HistoryListView(viewModel: viewModel)
        } detail: {
            HistoryDetailView(viewModel: viewModel)
        }
        .navigationSplitViewStyle(.balanced)
        .searchable(text: $viewModel.searchText, placement: .toolbar,
                    prompt: "Search title or body")
        // The automatic one sits *after* the window title, which is not
        // where a Mac user looks for it — see `sidebarToggleButton`.
        .toolbar(removing: .sidebarToggle)
        .toolbar(id: "history") {
            // `.navigation` is the leading group, before the title: the
            // sidebar toggle then the compose button, which is the order
            // Mail and Notes use.
            ToolbarItem(id: "sidebar", placement: .navigation) {
                sidebarToggleButton
            }
            ToolbarItem(id: "newMessage", placement: .navigation) {
                newMessageButton
            }
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

    /// This app's own sidebar toggle, replacing the one `NavigationSplitView`
    /// installs for itself.
    ///
    /// The automatic item is placed after the window title — "All Messages",
    /// then the toggle — where every Mac app with a sidebar puts it between
    /// the traffic lights and the title. Reported as exactly that. There is
    /// no way to reposition the automatic item, so it is removed
    /// (`.toolbar(removing: .sidebarToggle)`) and replaced with one placed
    /// explicitly.
    ///
    /// Driving `columnVisibility` directly is also what makes the state
    /// legible: the automatic toggle mutates visibility privately, so
    /// nothing else in this view could know or influence which columns are
    /// showing.
    private var sidebarToggleButton: some View {
        Button {
            withAnimation {
                // `.doubleColumn` is "content and detail" — the sidebar
                // hidden — in a three-column split view. `.detailOnly` would
                // hide the message list too, which is not what this control
                // means.
                columnVisibility = columnVisibility == .all ? .doubleColumn : .all
            }
        } label: {
            Label("Hide Sidebar", systemImage: "sidebar.leading")
        }
        .help("Hide or show the sidebar")
    }

    /// New Message. A `plus` rather than Mail's `square.and.pencil` because
    /// that is what was asked for, and because this app publishes to a topic
    /// rather than composing correspondence — the pencil implies a reply
    /// surface that does not exist here.
    private var newMessageButton: some View {
        Button(action: onNewMessage) {
            Label("New Message", systemImage: "plus")
        }
        .help("New Message (⌘N)")
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
