import AppKit
import CoreGraphics
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

/// How many distinct colours a rendered PNG contains, **composited onto an
/// opaque white ground first**.
///
/// **Use this, not a byte-count floor.** A PNG of a completely blank surface
/// is not small — it is 38,199 bytes at the History window's size and 18,960
/// at the Settings tabs', because the encoder still writes a full-resolution
/// image. Every byte floor originally written against these surfaces was
/// calibrated by eye and sat *below* its own blank render, so thirteen
/// snapshot tests could not have failed on a surface that drew nothing.
///
/// Byte counts are also resolution-dependent: `bitmapImageRepForCachingDisplay`
/// returns a 2x rep on a Retina display and 1x elsewhere, so the same
/// assertion has different sensitivity on a dev machine and a CI runner.
///
/// **Why the white composite is essential, and not a detail.** These renders
/// have an alpha channel, and a view that paints no ground of its own draws
/// its content as colour-with-alpha over transparency. An earlier version of
/// this function quantised R/G/B and ignored alpha, which produced *two*
/// opposite errors:
///
/// - `ContentUnavailableView` drew black text at varying alpha over a
///   transparent ground. Every pixel had RGB `(0,0,0)`, so it counted **1
///   colour** for a view that looks perfectly correct — a false failure, which
///   is the kind that gets a guard disabled rather than fixed.
/// - It happened to catch the invisible-text bug for the opposite reason, by
///   accident rather than by design.
///
/// Compositing onto opaque white models what a viewer actually sees, since an
/// unpainted view in a real window shows the window's light backing.
///
/// **This function answers one question only: did the surface draw anything?**
/// It does *not* detect the invisible-text bug. An earlier alpha-ignoring
/// version appeared to, and that was luck rather than design — measured after
/// the composite, a render with its background deliberately removed still
/// counts 33, because the elements that remain visible against white are
/// plenty. Use `meanAlpha` for that; the two are complementary and a hosted
/// root wants both.
///
/// Measured on this suite: blank 1; `ContentUnavailableView` with no ground
/// 16; Settings servers-empty 27; onboarding dark 52; History populated 52;
/// menu bar populated 70.
@MainActor
func distinctColorCount(ofPNGAt path: String, sampleEvery stride: Int = 3) throws -> Int {
    guard let image = NSImage(contentsOfFile: path),
          let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let cgImage = rep.cgImage else {
        throw SnapshotError.couldNotAllocateBitmap
    }

    let width = rep.pixelsWide, height = rep.pixelsHigh
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw SnapshotError.couldNotAllocateBitmap
    }
    // The opaque ground, drawn before the image: this is the composite.
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

    var seen = Set<Int>()
    for y in Swift.stride(from: 0, to: height, by: stride) {
        for x in Swift.stride(from: 0, to: width, by: stride) {
            let offset = (y * width + x) * 4
            // Quantised to 5 bits per channel so imperceptible antialiasing
            // noise does not inflate the count.
            let r = Int(pixels[offset]) >> 3
            let g = Int(pixels[offset + 1]) >> 3
            let b = Int(pixels[offset + 2]) >> 3
            seen.insert(r << 10 | g << 5 | b)
        }
    }
    return seen.count
}


/// Mean alpha of a rendered PNG, 0 (fully transparent) to 1 (fully opaque).
///
/// **This is the direct test for the bug that shipped three times here.** A
/// SwiftUI root hosted in an `NSHostingView` has nothing behind it painting a
/// surface; if it does not paint its own, it renders transparent and the user
/// sees its text against the window's light backing — near-white on white in
/// dark mode, invisible.
///
/// Every other instrument detects that only indirectly and unreliably. Byte
/// counts do not (a broken render is *larger* than a correct one). A
/// light-vs-dark divergence does not (the broken pair diverges more than the
/// correct pair, so the comparison is inverted). A distinct-colour count does
/// not once the render is composited. Alpha is the property that actually
/// differs, so measuring it is both simpler and honest.
///
/// A view that paints its own ground returns ~1.0. Measured on this suite:
/// onboarding with its background 1.0, the same pane with it removed 0.053.
@MainActor
func meanAlpha(ofPNGAt path: String, sampleEvery stride: Int = 3) throws -> Double {
    guard let image = NSImage(contentsOfFile: path),
          let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let cgImage = rep.cgImage else {
        throw SnapshotError.couldNotAllocateBitmap
    }
    let width = rep.pixelsWide, height = rep.pixelsHigh
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: colorSpace,
            // `premultipliedLast` rather than `last`: a non-premultiplied
            // 8-bit context is not a supported CGBitmapContext format on
            // macOS, and premultiplication scales only R/G/B — the alpha
            // byte itself is stored unmodified, which is the only channel
            // this function reads.
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw SnapshotError.couldNotAllocateBitmap
    }
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

    var total = 0.0
    var samples = 0
    for y in Swift.stride(from: 0, to: height, by: stride) {
        for x in Swift.stride(from: 0, to: width, by: stride) {
            total += Double(pixels[(y * width + x) * 4 + 3]) / 255.0
            samples += 1
        }
    }
    guard samples > 0 else { throw SnapshotError.couldNotAllocateBitmap }
    return total / Double(samples)
}


/// Whether snapshot rendering should run here at all.
///
/// **Two separate reasons to say no, and the second was a surprise.**
///
/// *No window server.* These tests draw through AppKit — a real
/// `NSHostingView` in a real `NSWindow` captured with `cacheDisplay`.
/// Without a GUI session `bitmapImageRepForCachingDisplay` returns nil and
/// the render throws. `CGSessionCopyCurrentDictionary` answers that, and is
/// not main-actor isolated — which matters, because a trait's condition is
/// evaluated at registration on an arbitrary thread. An earlier attempt
/// probed the real thing behind `MainActor.assumeIsolated` and trapped
/// immediately with signal 5.
///
/// *On CI, even where rendering works.* The GitHub runner does have a
/// session, and these tests genuinely passed there — but twenty-two
/// window-creating tests running in parallel with the socket-level
/// `MockNtfyServer` suite starved it. Nineteen `ServerConnectionTests`
/// timed out, and a helper asserting a 200ms bound measured **1.674s**. The
/// renders were fine; everything around them was not.
///
/// So they are skipped on CI deliberately. They are a local verification
/// tool — the thing that caught six invisible-in-dark-mode surfaces — and
/// what CI is for here is the logic and networking they were drowning out.
/// A skip reads as a skip rather than a pass, so their absence stays visible.
nonisolated let snapshotRenderingIsAvailable: Bool = {
    guard ProcessInfo.processInfo.environment["CI"] == nil else { return false }
    return CGSessionCopyCurrentDictionary() != nil
}()

/// Applied to every test that renders. Reads as a skip in the results rather
/// than a pass, so a machine that silently stops rendering is visible instead
/// of quietly covering nothing.
let requiresSnapshotRendering = ConditionTrait.enabled(
    if: snapshotRenderingIsAvailable,
    "needs a window server, and is skipped on CI where these renders starve the socket-level tests")
