import AppKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    // Held for the app's lifetime: UNUserNotificationCenter.delegate is weak.
    // Authorization is requested after an explanatory pane, never here as a
    // cold prompt (spec §6) — that pane, and hooking decision output into
    // `present(_:)`, is later wiring.
    private let notificationPresenter = NotificationPresenter()

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = notificationPresenter

        // Menu-bar-first: no Dock icon until a window opens (spec §7).
        NSApp.setActivationPolicy(.accessory)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let image = NSImage(systemSymbolName: "bell", accessibilityDescription: "NtfyMe")
        image?.isTemplate = true
        item.button?.image = image

        let menu = NSMenu()
        menu.addItem(
            withTitle: "Quit NtfyMe",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        item.menu = menu

        statusItem = item
    }
}
