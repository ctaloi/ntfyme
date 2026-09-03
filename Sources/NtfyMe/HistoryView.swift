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
    /// with no app around it at all. `nil` is the plain ⌘N; a seed routes
    /// "send to this topic" from the detail pane or a row's context menu
    /// through the same single path to one Compose window.
    var onNewMessage: (ComposeSeed?) -> Void = { _ in }
    /// Opens Settings on the Servers tab — the Add Subscription toolbar
    /// button's whole job. Injected like `onNewMessage` for the same reasons.
    var onAddSubscription: () -> Void = {}

    /// Driven by this view's own sidebar toggle rather than left to the
    /// automatic one — see `sidebarToggleButton`.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            HistorySidebarView(viewModel: viewModel,
                               onComposeToTopic: { onNewMessage($0) })
                // On the sidebar's *content*, not on the split view. The
                // automatic toggle belongs to the column that owns the
                // sidebar, and applying this one level up silently does
                // nothing — which shipped as two sidebar buttons, the
                // replacement before the title and the original still after
                // it.
                .toolbar(removing: .sidebarToggle)
        } content: {
            HistoryListView(viewModel: viewModel,
                            onComposeToTopic: { onNewMessage($0) })
        } detail: {
            HistoryDetailView(viewModel: viewModel,
                              onComposeToTopic: { onNewMessage($0) })
        }
        .navigationSplitViewStyle(.balanced)
        .searchable(text: $viewModel.searchText, placement: .toolbar,
                    prompt: "Search title or body")
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
            ToolbarItem(id: "addSubscription", placement: .navigation) {
                addSubscriptionButton
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
    /// New Message. A paperplane, not Mail's `square.and.pencil` and —
    /// pointedly — not the `plus` it used to be: the paperplane is what the
    /// Compose window's Send button and the popover's compose button both
    /// already say, and freeing `plus` up is what lets the toolbar's second
    /// button mean *create* without two buttons wearing the same glyph.
    /// This app publishes to a topic rather than composing correspondence;
    /// the pencil implied a reply surface that does not exist here.
    private var newMessageButton: some View {
        Button { onNewMessage(nil) } label: {
            Label("New Message", systemImage: "paperplane.fill")
        }
        .help("New Message (⌘N)")
    }

    /// Add Subscription — the creating-new-things half of the toolbar.
    /// `plus` because it creates a subscription rather than sending
    /// anything, and it lands on Settings → Servers, where subscriptions
    /// actually live, rather than inventing a second topic-adding UI on
    /// this window. One place to add a topic; many doors to it.
    private var addSubscriptionButton: some View {
        Button(action: onAddSubscription) {
            Label("Add Subscription", systemImage: "plus")
        }
        .help("Add a topic to follow…")
    }


}
