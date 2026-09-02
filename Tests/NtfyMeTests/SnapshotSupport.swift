import AppKit
import SwiftUI
import Testing

/// Renders a SwiftUI view to a PNG with no window on screen.
///
/// **Why not `ImageRenderer`.** The obvious choice does not work for this app.
/// `ImageRenderer` renders `ScrollView` content as blank and draws `Button`
/// and `TextField` as a yellow placeholder box — so a snapshot of any surface
/// here comes out as empty chrome that *looks* like a successful render. Every
/// interesting part of the menu bar popover and the History window lives
/// inside a scroll view, which made the first round of snapshots worthless in
/// exactly the way that is hardest to notice.
///
/// This goes through AppKit's real drawing path instead: a real `NSHostingView`
/// in a real (never-ordered-front) `NSWindow`, drawn with `cacheDisplay`. That
/// is the same path the app uses on screen, so what comes out is what a user
/// would see. Verified against a probe containing all three problem cases.
///
/// - Parameters:
///   - size: render at the surface's real size — a snapshot at an invented
///     size verifies a layout the user will never look at.
///   - colorScheme: sets the window's `NSAppearance` as well as the SwiftUI
///     environment. Both are needed: AppKit draws the controls and honours the
///     appearance, SwiftUI draws the rest and honours the environment, and
///     setting only one produces a half-dark render that is worse than either.
@MainActor
func renderSnapshot(
    _ view: some View,
    size: CGSize,
    colorScheme: ColorScheme = .light,
    to filename: String,
    directory: String = "/tmp/ntfyshots"
) throws -> Int {
    let hosting = NSHostingView(
        rootView: view
            .environment(\.colorScheme, colorScheme)
            .frame(width: size.width, height: size.height))
    hosting.frame = NSRect(origin: .zero, size: size)

    let window = NSWindow(contentRect: hosting.frame,
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
    window.contentView = hosting
    // Both are needed: the window lays out its content view, the hosting view
    // lays out the SwiftUI tree inside it. Skipping the second yields a render
    // of the pre-layout frame, which is usually empty.
    window.layoutIfNeeded()
    hosting.layoutSubtreeIfNeeded()

    guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
        throw SnapshotError.couldNotAllocateBitmap
    }
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw SnapshotError.couldNotEncodePNG
    }

    try FileManager.default.createDirectory(
        atPath: directory, withIntermediateDirectories: true)
    try png.write(to: URL(filePath: directory).appending(path: filename))
    return png.count
}

enum SnapshotError: Error {
    case couldNotAllocateBitmap
    case couldNotEncodePNG
}
