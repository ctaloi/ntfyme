import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
