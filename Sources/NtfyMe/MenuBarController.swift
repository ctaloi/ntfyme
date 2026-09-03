import AppKit
import Combine
import SwiftUI
import NtfyKit

/// Owns the `NSStatusItem` and `NSPopover`. Deliberately AppKit for the
/// status item — spec §7: as of macOS 26 `MenuBarExtra` still cannot do a
/// right-click context menu, custom icon badging, or programmatic open, and
/// this app needs all three (notably so a notification click can surface the
/// popover later). SwiftUI renders only the popover's contents
/// (`MenuBarPopoverView`).
///
/// Nothing here pushes updates on its own: `ConnectionCoordinator.state(forServer:)`
/// is pull-only and the store has no change stream, so the icon and badge are
/// only ever as fresh as the last `refreshNow()`. The wiring pass owns
/// deciding when that is — after a stored batch, on wake, on a timer, and
/// whenever the popover is about to show.
@MainActor
final class MenuBarController: NSObject {
    /// Set by the wiring pass. Both the right-click menu and the popover's
    /// own History/Settings buttons call these, so there is one place that
    /// knows how to reach the History window and the Settings scene rather
    /// than two.
    var onOpenHistory: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    /// Takes the tapped message's unique key (`MessageSnapshot.id`) — the
    /// wiring pass opens History and reveals that message by key. Wrapped in
    /// `configurePopover()` to close the popover first: leaving it floating
    /// over the window it just summoned would be wrong.
    var onOpenMessage: (String) -> Void = { _ in }
    /// Reconnects every server (`ConnectionCoordinator.reconnectAll()` on
    /// the wiring pass's side). Unlike `onOpenMessage`, this does not close
    /// the popover — retrying doesn't summon another window, and the user
    /// likely wants to watch the status row update.
    var onRetryConnection: () -> Void = {}
    /// Defaults to the standard terminate call — unlike History and
    /// Settings, quitting needs nothing from another agent's types.
    var onQuit: () -> Void = { NSApplication.shared.terminate(nil) }

    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let viewModel: MenuBarViewModel
    private var cancellables = Set<AnyCancellable>()

    init(dependencies: MenuBarViewModel.Dependencies) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        viewModel = MenuBarViewModel(dependencies: dependencies)
        super.init()

        configureStatusItem()
        configurePopover()
        observeViewModel()
        updateIcon(unreadCount: 0, statuses: [])
    }

    /// Re-fetches messages and connection status and updates the icon
    /// accordingly, whether or not the popover is currently open. This is
    /// the method a notification-stored hook, a wake-from-sleep observer, or
    /// a periodic timer should call — see this type's doc comment.
    func refreshNow() async {
        await viewModel.refresh()
    }

    /// Opens the popover programmatically — e.g. a notification click
    /// surfacing it, once that wiring exists.
    func showPopover() {
        guard !popover.isShown, let button = statusItem.button else { return }
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func closePopover() {
        popover.performClose(nil)
    }

    // MARK: - Status item

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp ||
            (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true)

        if isRightClick {
            showContextMenu()
        } else if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showContextMenu() {
        // `statusItem.menu` must stay nil the rest of the time: if it were
        // always assigned, AppKit routes every click to the menu and the
        // button never sends `statusItemClicked(_:)` again, which is what
        // would make left-click toggling the popover permanently.
        let menu = NSMenu()
        menu.addItem(withTitle: "Open NtfyMe", action: #selector(menuOpenPopover), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "History…", action: #selector(menuOpenHistory), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Settings…", action: #selector(menuOpenSettings), keyEquivalent: ",")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit NtfyMe", action: #selector(menuQuit), keyEquivalent: "q")
            .target = self

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func menuOpenPopover() { showPopover() }
    @objc private func menuOpenHistory() { onOpenHistory() }
    @objc private func menuOpenSettings() { onOpenSettings() }
    @objc private func menuQuit() { onQuit() }

    // MARK: - Popover

    private func configurePopover() {
        popover.behavior = .transient // dismisses on click-outside
        popover.contentSize = MenuBarPopoverView.size
        popover.contentViewController = NSHostingController(
            rootView: MenuBarPopoverView(
                viewModel: viewModel,
                onOpenHistory: { [weak self] in self?.onOpenHistory() },
                onOpenSettings: { [weak self] in self?.onOpenSettings() },
                onQuit: { [weak self] in self?.onQuit() },
                onOpenMessage: { [weak self] uniqueKey in
                    self?.closePopover()
                    self?.onOpenMessage(uniqueKey)
                },
                onRetryConnection: { [weak self] in self?.onRetryConnection() }
            )
        )
    }

    // MARK: - Icon

    private func observeViewModel() {
        viewModel.$unreadCount.combineLatest(viewModel.$serverStatuses)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] unreadCount, statuses in
                self?.updateIcon(unreadCount: unreadCount, statuses: statuses)
            }
            .store(in: &cancellables)
    }

    /// `SettingsGeneralTab`'s "Badge the menu bar icon with the unread
    /// count" toggle — that view owns the `@AppStorage` binding, this reads
    /// the same key from the `UserDefaults` it actually lands in. Not
    /// modeled in `Preferences` (see that tab's own doc comment on the
    /// property), so there is no store method to call instead.
    private static let badgeMenuBarIconKey = "settings.general.badgeMenuBarIcon"

    /// `UserDefaults.bool(forKey:)` alone would return `false` — "off" —
    /// for a key nobody has written yet, which is every install that has
    /// never opened Settings. `@AppStorage`'s own default is `true`, so an
    /// absent key has to mean the same thing here, not the opposite.
    private func badgingEnabled() -> Bool {
        guard UserDefaults.standard.object(forKey: Self.badgeMenuBarIconKey) != nil else {
            return true
        }
        return UserDefaults.standard.bool(forKey: Self.badgeMenuBarIconKey)
    }

    private func updateIcon(unreadCount: Int, statuses: [MenuBarServerStatus]) {
        let connectivity = MenuBarConnectivity.summarize(statuses)
        let needsAttention = connectivity == .disconnected || connectivity == .needsAttention
        let showBadge = unreadCount > 0 && badgingEnabled()
        let symbolName = needsAttention ? "bell.slash" : (showBadge ? "bell.badge" : "bell")
        setSymbol(symbolName)

        // The accessibility label always states the real unread count,
        // independent of the badge preference: that toggle is about the
        // glyph shown on screen, not about withholding state from
        // VoiceOver.
        let unreadText = unreadCount > 0 ? "\(unreadCount) unread. " : ""
        statusItem.button?.setAccessibilityLabel("NtfyMe. \(unreadText)\(connectivity.statusText).")
    }

    /// `NSImage(systemSymbolName:)` returns `nil` for a name the running OS
    /// doesn't recognize. Every name used here is a long-standing SF Symbol,
    /// but a missing image must never leave the status item a blank,
    /// zero-width button — the fallback keeps something clickable on screen.
    private func setSymbol(_ name: String) {
        guard let button = statusItem.button else { return }
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
            image.isTemplate = true
            button.image = image
            button.title = ""
        } else {
            Log.app.error("status item symbol lookup failed; falling back to text")
            button.image = nil
            button.title = "Ntfy"
        }
    }
}
