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
    // `.atomic` is load-bearing now that assertions read the file back off
    // disk instead of using the in-memory byte count. Two tests rendering the
    // same filename in parallel previously risked only a torn artifact a human
    // might notice; with `distinctColorCount` reading through
    // `NSImage(contentsOfFile:)`, a torn write becomes a real flake or a false
    // pass. Filenames must still be unique per test — this only makes a
    // collision fail honestly rather than silently.
    try png.write(to: URL(filePath: directory).appending(path: filename), options: .atomic)
    return png.count
}

enum SnapshotError: Error {
    case couldNotAllocateBitmap
    case couldNotEncodePNG
}

/// Mean luminance of a rendered PNG, 0 (black) to 1 (white).
///
/// **Why byte counts are not enough.** A dark-mode render of a view that
/// forgot its background differs from its light counterpart — the text
/// antialiasing changes — so a byte-count divergence check passes while every
/// word on the screen is white-on-white and unreadable. That exact bug shipped
/// past a divergence assertion three times in this app. Luminance catches it:
/// a dark render of a correct view is dark.
@MainActor
func meanLuminance(ofPNGAt path: String) throws -> Double {
    guard let image = NSImage(contentsOfFile: path),
          let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else {
        throw SnapshotError.couldNotAllocateBitmap
    }
    var total = 0.0
    var samples = 0
    // Every 4th pixel on both axes: 16x fewer samples, same answer to well
    // beyond the precision this assertion needs.
    for y in stride(from: 0, to: rep.pixelsHigh, by: 4) {
        for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
            guard let c = rep.colorAt(x: x, y: y) else { continue }
            total += 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
            samples += 1
        }
    }
    guard samples > 0 else { throw SnapshotError.couldNotAllocateBitmap }
    return total / Double(samples)
}

/// How many distinct colours a rendered PNG contains.
///
/// **Use this, not a byte-count floor.** A PNG of a completely blank surface
/// is not small — it is 38,199 bytes at the History window's size and 18,960
/// at the Settings tabs', because the encoder still writes a full-resolution
/// image. Measured on this machine, not estimated. Every byte floor written
/// against these surfaces was calibrated by eye and sat *below* its own blank
/// render, so thirteen snapshot tests could not have failed on a surface that
/// drew nothing at all — the exact regression they existed to catch.
///
/// Byte counts are also resolution-dependent: `bitmapImageRepForCachingDisplay`
/// returns a 2x rep on a Retina display and 1x elsewhere, so the same
/// assertion has different sensitivity on a dev machine and a CI runner.
///
/// A distinct-colour count does not have either problem. A blank surface has
/// one or two colours whatever its size or scale; a real one has dozens, from
/// text antialiasing alone.
///
/// **Do not fold alpha into the key.** Quantising only R/G/B is what makes
/// this catch the invisible-text bug as well as the blank one: a view that
/// paints no opaque ground renders with almost no colour variation and
/// collapses to one or two entries, even though at byte level it differs from
/// its light counterpart in almost every pixel. Measured against the real
/// popover regression at its real size — broken 1-2 colours, fixed 25-29,
/// blank 1. Folding alpha in would look like an improvement in precision and
/// would silently delete that protection.
@MainActor
func distinctColorCount(ofPNGAt path: String, sampleEvery stride: Int = 3) throws -> Int {
    guard let image = NSImage(contentsOfFile: path),
          let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else {
        throw SnapshotError.couldNotAllocateBitmap
    }
    var seen = Set<Int>()
    for y in Swift.stride(from: 0, to: rep.pixelsHigh, by: stride) {
        for x in Swift.stride(from: 0, to: rep.pixelsWide, by: stride) {
            guard let c = rep.colorAt(x: x, y: y) else { continue }
            // Quantised to 5 bits per channel: ignores imperceptible
            // antialiasing noise while still separating real content.
            let r = Int(c.redComponent * 31), g = Int(c.greenComponent * 31), b = Int(c.blueComponent * 31)
            seen.insert(r << 10 | g << 5 | b)
        }
    }
    return seen.count
}
