import SwiftUI
import NtfyKit

/// The History window's root view: a three-column `NavigationSplitView` —
/// sidebar (scope), list (search + filters), detail (selected message).
struct HistoryView: View {
    @Bindable var viewModel: HistoryViewModel

    var body: some View {
        NavigationSplitView {
            HistorySidebarView(viewModel: viewModel)
        } content: {
            HistoryListView(viewModel: viewModel)
        } detail: {
            HistoryDetailView(viewModel: viewModel)
        }
        .navigationSplitViewStyle(.balanced)
    }
}
