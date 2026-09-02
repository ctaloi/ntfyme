# NtfyMe Foundation Implementation Plan (Stages 1–2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A signed, launchable menu-bar app shell plus a fully tested `NtfyKit` core that can connect to an ntfy server, stream messages, and recover from disconnects — with no UI and no persistence yet.

**Architecture:** Two SwiftPM targets. `NtfyKit` is a pure library (no AppKit, no SwiftUI) holding wire models, URL construction, an ndjson stream client, and a per-server connection actor with a keepalive watchdog and backoff. `NtfyMe` is a thin executable that currently does nothing but put a status item in the menu bar. Tests run against `MockNtfyServer`, a real loopback HTTP server, so reconnect logic is exercised over an actual socket rather than a mock object.

**Tech Stack:** Swift 6.2, SwiftPM, Swift Testing (`import Testing`), Foundation `URLSession.bytes`, Network.framework (test server only), AppKit `NSStatusItem`, SwiftUI `Settings` scene.

**Spec:** `docs/superpowers/specs/2026-09-02-mac-ntfy-design.md` — read it before starting. This plan implements §3, §5, §9, §11, and §12; it does not touch §4 (persistence), §6 (notifications), §7 (UI), or §8 (retention).

## Global Constraints

Copied verbatim from the spec. Every task's requirements implicitly include these.

- **Product name:** `NtfyMe`. **Bundle identifier:** `dev.aloi.NtfyMe`. **License:** MIT.
- **Platform floor:** macOS 26 (`.macOS(.v26)` in `Package.swift`, `LSMinimumSystemVersion` `26.0`).
- **Toolchain:** Xcode 26.6 reached via `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. Never run `sudo xcode-select`.
- **The repository is public.** No credentials, tokens, personal server URLs, personal topic names, internal hostnames, or signing material may appear in any committed file — **including test fixtures**. Sanitize every captured payload to `example.com` and generic topic names before committing it.
- **No silent failures.** Every error path either surfaces to a caller or is logged with enough detail to diagnose. Never `try?` away an error without a comment justifying it.
- **`NtfyKit` imports no UI framework.** No `import AppKit`, no `import SwiftUI`. This is what keeps it testable; a reviewer should reject any task that breaks it.
- **Message bodies are sensitive** (they routinely carry hostnames and URLs). Never log a message body at default log level.
- **Swift 6 language mode**, strict concurrency. Public types crossing concurrency boundaries must be `Sendable`.

## Measured ntfy behavior this plan depends on

Verified against ntfy.sh on 2026-09-02. Do not re-derive these from documentation; they were measured.

| Fact | Consequence for this plan |
|---|---|
| `GET /a,b,c/json` streams all three topics; every message carries its own `topic` field | One connection per server, demultiplexed client-side (Task 7, Task 10) |
| `since=<unix ts>` is a **lower bound**, returning everything from that point to now | No race between backfill and stream rebuild (Task 4) |
| `since=<12-char id>` resolves **across** a multi-topic subscription | Recorded, but not used for resume — see next row |
| `since=<well-formed but unknown/evicted id>` returns **HTTP 200 and the full cache**, no error | Why resume uses timestamps: an ID failure is indistinguishable from success (Task 4) |
| `since=<malformed value>` returns **HTTP 400** `{"code":40008,"error":"invalid since parameter"}` | Treated as a client bug: log loudly, fall back to `since=all` (Task 7) |
| Stream sends an `open` event first, then `message` / `keepalive` (~45s) | Watchdog resets on any line; `open` resets backoff (Task 6, Task 10) |

## File Structure

```
Package.swift                              SwiftPM manifest, both targets
LICENSE                                    MIT
README.md                                  What it is, build instructions, the topics-are-passwords warning
.gitignore                                 .build/, *.app, Scripts/local.sh, .DS_Store

Scripts/
  config.sh                                Bundle ID, version, default signing identity
  build-app.sh                             swift build -> .app assembly -> codesign -> optional notarize
  Info.plist.in                            Template, substituted by build-app.sh
  NtfyMe.entitlements                      network.client (+ time-sensitive, see Task 1)

Sources/NtfyKit/
  Models/NtfyEvent.swift                   Wire type for one ndjson line
  Models/NtfyAction.swift                  view / http / broadcast / copy
  Models/NtfyAttachment.swift              name, url, type, size, expires
  Models/NtfyPriority.swift                1-5 with named cases
  Networking/AuthCredential.swift          none / bearer / basic, header construction
  Networking/NtfyEndpoint.swift            URL + request construction
  Networking/SinceParameter.swift          all / unixTime / messageID, query encoding
  Networking/WatermarkResolver.swift       min() across subscriptions, gap detection
  Networking/BackoffPolicy.swift           Exponential + jitter, injectable RNG
  Networking/KeepaliveWatchdog.swift       Actor, injectable clock
  Networking/NtfyEventDecoder.swift        One line -> Outcome
  Networking/NtfyStreamClient.swift        URLSession.bytes -> AsyncThrowingStream
  Networking/ConnectionState.swift         State enum + transitions
  Networking/ServerConnection.swift        The actor that ties it together
  Security/KeychainStore.swift             Credential storage keyed by server UUID

Sources/NtfyMe/
  NtfyMeApp.swift                          @main App, Settings scene
  AppDelegate.swift                        Activation policy + status item

Tests/NtfyKitTests/
  Support/MockNtfyServer.swift             Loopback HTTP server streaming scripted ndjson
  Support/Fixtures.swift                   Sanitized JSON fixtures
  NtfyEventDecodingTests.swift
  NtfyEventDecoderTests.swift
  SinceParameterTests.swift
  WatermarkResolverTests.swift
  BackoffPolicyTests.swift
  KeepaliveWatchdogTests.swift
  NtfyEndpointTests.swift
  AuthCredentialTests.swift
  NtfyStreamClientTests.swift
  ServerConnectionTests.swift
  KeychainStoreTests.swift

.github/workflows/ci.yml                   Build + test, unsigned
```

---

### Task 1: Package skeleton, repo hygiene, and a launchable menu-bar app

Proves the whole build path end to end before any feature exists. This is deliberately first: if `.app` assembly, signing, or entitlements are broken, everything after it is built on sand.

**Files:**
- Create: `Package.swift`, `LICENSE`, `README.md`, `.gitignore`
- Create: `Scripts/config.sh`, `Scripts/build-app.sh`, `Scripts/Info.plist.in`, `Scripts/NtfyMe.entitlements`
- Create: `Sources/NtfyKit/NtfyKit.swift`, `Sources/NtfyMe/NtfyMeApp.swift`, `Sources/NtfyMe/AppDelegate.swift`
- Create: `Tests/NtfyKitTests/PackageSmokeTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `NtfyKit.version: String`. The `swift build` / `swift test` invocation shape every later task uses. `Scripts/build-app.sh` producing `build/NtfyMe.app`.

- [ ] **Step 1: Write the failing smoke test**

`Tests/NtfyKitTests/PackageSmokeTests.swift`:

```swift
import Testing
@testable import NtfyKit

@Test func kitExposesAVersion() {
    #expect(!NtfyKit.version.isEmpty)
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test 2>&1 | tail -20
```

Expected: FAIL — no `Package.swift` yet, so the build errors out before the test runs.

- [ ] **Step 3: Write `Package.swift`**

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NtfyMe",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "NtfyKit", targets: ["NtfyKit"]),
        .executable(name: "NtfyMe", targets: ["NtfyMe"]),
    ],
    targets: [
        .target(name: "NtfyKit"),
        .executableTarget(name: "NtfyMe", dependencies: ["NtfyKit"]),
        .testTarget(name: "NtfyKitTests", dependencies: ["NtfyKit"]),
    ]
)
```

- [ ] **Step 4: Write the minimal `NtfyKit` source**

`Sources/NtfyKit/NtfyKit.swift`:

```swift
import Foundation

/// Namespace for package-level metadata.
public enum NtfyKit {
    /// Marketing version of the library, kept in step with `Scripts/config.sh`.
    public static let version = "0.1.0"
}
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
swift test --filter kitExposesAVersion 2>&1 | tail -20
```

Expected: PASS.

- [ ] **Step 6: Write the app entry point**

`Sources/NtfyMe/NtfyMeApp.swift`. The file must **not** be named `main.swift` — `@main` and a top-level `main.swift` are mutually exclusive in SwiftPM.

```swift
import SwiftUI

@main
struct NtfyMeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            // Replaced with the real settings tabs in a later plan.
            Text("NtfyMe")
                .padding()
                .frame(width: 320, height: 120)
        }
    }
}
```

`Sources/NtfyMe/AppDelegate.swift`:

```swift
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
```

- [ ] **Step 7: Write the build configuration**

`Scripts/config.sh`:

```bash
#!/usr/bin/env bash
# Shared build configuration. Sourced by build-app.sh.
#
# PRODUCT_BUNDLE_ID is effectively permanent: macOS keys notification
# authorization and Keychain ACLs to it. Changing it after a build has been
# installed revokes notification permission and orphans stored credentials.
# Forks should change it before their first build, or not at all.
PRODUCT_NAME="NtfyMe"
PRODUCT_BUNDLE_ID="dev.aloi.NtfyMe"
MARKETING_VERSION="0.1.0"
BUILD_VERSION="1"
MINIMUM_MACOS="26.0"

# Override in Scripts/local.sh (gitignored) or the environment.
SIGN_IDENTITY="${SIGN_IDENTITY:-Apple Development}"
NOTARIZE="${NOTARIZE:-0}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

# An `if` guard, not `[ -f x ] && . x`: a failing left side of a top-level
# `&&` list makes the sourced file return non-zero, which aborts build-app.sh
# under `set -euo pipefail` — and local.sh being absent is the normal case.
if [ -f "$(dirname "${BASH_SOURCE[0]}")/local.sh" ]; then
    . "$(dirname "${BASH_SOURCE[0]}")/local.sh"
fi
```

`Scripts/Info.plist.in`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>__PRODUCT_NAME__</string>
    <key>CFBundleDisplayName</key><string>__PRODUCT_NAME__</string>
    <key>CFBundleExecutable</key><string>__PRODUCT_NAME__</string>
    <key>CFBundleIdentifier</key><string>__BUNDLE_ID__</string>
    <key>CFBundleShortVersionString</key><string>__MARKETING_VERSION__</string>
    <key>CFBundleVersion</key><string>__BUILD_VERSION__</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>__MINIMUM_MACOS__</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>MIT licensed</string>
</dict>
</plist>
```

`Scripts/NtfyMe.entitlements` — start with network only. Step 10 decides whether the time-sensitive entitlement can join it.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.network.client</key><true/>
</dict>
</plist>
```

- [ ] **Step 8: Write `Scripts/build-app.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
. "$HERE/config.sh"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

CONFIG="${CONFIG:-release}"
APP="$ROOT/build/$PRODUCT_NAME.app"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG" --package-path "$ROOT"
BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)/$PRODUCT_NAME"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$PRODUCT_NAME"

sed -e "s|__PRODUCT_NAME__|$PRODUCT_NAME|g" \
    -e "s|__BUNDLE_ID__|$PRODUCT_BUNDLE_ID|g" \
    -e "s|__MARKETING_VERSION__|$MARKETING_VERSION|g" \
    -e "s|__BUILD_VERSION__|$BUILD_VERSION|g" \
    -e "s|__MINIMUM_MACOS__|$MINIMUM_MACOS|g" \
    "$HERE/Info.plist.in" > "$APP/Contents/Info.plist"

echo "==> codesign as: $SIGN_IDENTITY"
codesign --force --options runtime --timestamp \
    --entitlements "$HERE/$PRODUCT_NAME.entitlements" \
    --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

if [ "$NOTARIZE" = "1" ]; then
    [ -n "$NOTARY_PROFILE" ] || { echo "NOTARY_PROFILE required when NOTARIZE=1" >&2; exit 1; }
    echo "==> notarizing"
    ZIP="$ROOT/build/$PRODUCT_NAME.zip"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
fi

echo "==> built $APP"
```

Make it executable: `chmod +x Scripts/build-app.sh Scripts/config.sh`.

- [ ] **Step 9: Write repo hygiene files**

`.gitignore`:

```
.build/
build/
Scripts/local.sh
.DS_Store
*.xcuserstate
```

`LICENSE`: the standard MIT text, copyright `2026 Chris Aloi`.

`README.md` must state, in its own section, that **on public ntfy.sh a topic name is effectively a password** — anyone who knows it can read and publish to it — and that the app stores server credentials in the Keychain, never in the repository or its database.

- [ ] **Step 10: Build, launch, and verify — including the entitlement question**

```bash
Scripts/build-app.sh
open build/NtfyMe.app
```

Expected: a bell icon appears in the menu bar; clicking it shows "Quit NtfyMe"; Quit works.

Now determine whether the time-sensitive entitlement can be signed locally. Add `<key>com.apple.developer.usernotifications.time-sensitive</key><true/>` to `Scripts/NtfyMe.entitlements`, rebuild, and launch.

- If it builds, signs, and launches: keep it.
- If `codesign` fails, or the app is killed on launch: **remove it and record why in the README's Building section.** `com.apple.developer.*` entitlements generally require an embedded provisioning profile from an App ID with the capability enabled, which local Apple Development signing does not provide. This is expected, is not a blocker for Stages 1–2, and becomes a Stage 5 release task. Do not spend more than 15 minutes here.

Record the outcome either way — a later plan depends on knowing it.

- [ ] **Step 11: Commit**

```bash
git add -A
git commit -m "feat: package skeleton, build script, and launchable menu-bar shell"
```

---

### Task 2: Wire models and decoding

**Files:**
- Create: `Sources/NtfyKit/Models/NtfyPriority.swift`, `NtfyAction.swift`, `NtfyAttachment.swift`, `NtfyEvent.swift`
- Create: `Tests/NtfyKitTests/Support/Fixtures.swift`, `Tests/NtfyKitTests/NtfyEventDecodingTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `NtfyEvent` (`Sendable`, `Decodable`) with `id: String`, `time: Int`, `expires: Int?`, `event: String`, `topic: String`, `title: String?`, `message: String?`, `priority: Int?`, `tags: [String]?`, `click: String?`, `icon: String?`, `contentType: String?`, `actions: [NtfyAction]?`, `attachment: NtfyAttachment?`, and computed `kind: NtfyEvent.Kind?`, `date: Date`, `resolvedPriority: NtfyPriority`, `isMarkdown: Bool`. `NtfyEvent.Kind` enum: `.open`, `.message`, `.keepalive`, `.pollRequest`. `NtfyPriority` enum with `.min`/`.low`/`.default`/`.high`/`.max` and `init?(rawValue: Int)`. `NtfyAction`, `NtfyAttachment`.

- [ ] **Step 1: Write sanitized fixtures**

`Tests/NtfyKitTests/Support/Fixtures.swift`. **These are sanitized on purpose** — the repository is public, so no real hostnames or topic names. Shapes are taken from live ntfy.sh responses; values are not.

```swift
enum Fixtures {
    /// A full message: title, tags, click, one view action, markdown content type.
    static let richMessage = #"""
    {"id":"XhKkViRHS9hx","time":1788335966,"expires":1788379166,"event":"message","topic":"alerts","title":"Service recovered","message":"**db-01** back to healthy","priority":3,"tags":["white_check_mark"],"click":"https://example.com/status","actions":[{"id":"80ka2OegsR","action":"view","label":"Open","clear":false,"url":"https://example.com/hosts/1"}],"content_type":"text/markdown"}
    """#

    /// The minimum a message can be: no title, no tags, no priority.
    static let minimalMessage = #"""
    {"id":"J7rfOekQUOkP","time":1788353322,"expires":1788396522,"event":"message","topic":"alerts","message":"A1"}
    """#

    /// Sent first on every stream.
    static let openEvent = #"""
    {"id":"m7A9VeCXrXcV","time":1788352812,"event":"open","topic":"alerts"}
    """#

    static let keepaliveEvent = #"""
    {"id":"kA1","time":1788352857,"event":"keepalive","topic":"alerts"}
    """#

    /// An event type this version of the app does not know about.
    static let unknownEvent = #"""
    {"id":"zZ9","time":1788352900,"event":"some_future_event","topic":"alerts"}
    """#

    static let messageWithAttachment = #"""
    {"id":"att1","time":1788353000,"event":"message","topic":"alerts","message":"see attached","attachment":{"name":"graph.png","url":"https://example.com/f/graph.png","type":"image/png","size":4096,"expires":1788396200}}
    """#
}
```

- [ ] **Step 2: Write the failing decoding tests**

`Tests/NtfyKitTests/NtfyEventDecodingTests.swift`:

```swift
import Foundation
import Testing
@testable import NtfyKit

private func decode(_ json: String) throws -> NtfyEvent {
    try JSONDecoder().decode(NtfyEvent.self, from: Data(json.utf8))
}

@Test func decodesRichMessage() throws {
    let e = try decode(Fixtures.richMessage)
    #expect(e.id == "XhKkViRHS9hx")
    #expect(e.kind == .message)
    #expect(e.topic == "alerts")
    #expect(e.title == "Service recovered")
    #expect(e.priority == 3)
    #expect(e.tags == ["white_check_mark"])
    #expect(e.contentType == "text/markdown")
    #expect(e.actions?.count == 1)
    #expect(e.actions?.first?.action == .view)
    #expect(e.actions?.first?.label == "Open")
}

@Test func decodesMinimalMessage() throws {
    let e = try decode(Fixtures.minimalMessage)
    #expect(e.kind == .message)
    #expect(e.title == nil)
    #expect(e.priority == nil)
    #expect(e.tags == nil)
}

@Test func decodesOpenAndKeepalive() throws {
    #expect(try decode(Fixtures.openEvent).kind == .open)
    #expect(try decode(Fixtures.keepaliveEvent).kind == .keepalive)
}

/// Forward compatibility: an unknown event type must decode, not throw.
/// `kind` is nil so callers can ignore it without the stream dying.
@Test func decodesUnknownEventWithoutThrowing() throws {
    let e = try decode(Fixtures.unknownEvent)
    #expect(e.kind == nil)
    #expect(e.event == "some_future_event")
}

@Test func decodesAttachment() throws {
    let e = try decode(Fixtures.messageWithAttachment)
    #expect(e.attachment?.name == "graph.png")
    #expect(e.attachment?.size == 4096)
    #expect(e.attachment?.type == "image/png")
}

@Test func convertsTimeToDate() throws {
    let e = try decode(Fixtures.minimalMessage)
    #expect(e.date == Date(timeIntervalSince1970: 1_788_353_322))
}

@Test func mapsPriorityRawValues() {
    #expect(NtfyPriority(rawValue: 1) == .min)
    #expect(NtfyPriority(rawValue: 3) == .default)
    #expect(NtfyPriority(rawValue: 5) == .max)
    #expect(NtfyPriority(rawValue: 0) == nil)
    #expect(NtfyPriority(rawValue: 6) == nil)
}
```

- [ ] **Step 3: Run to verify it fails**

```bash
swift test --filter NtfyEventDecodingTests 2>&1 | tail -20
```

Expected: FAIL — `cannot find 'NtfyEvent' in scope`.

- [ ] **Step 4: Implement the models**

`Sources/NtfyKit/Models/NtfyPriority.swift`:

```swift
import Foundation

/// ntfy message priority. The wire format is 1...5; anything else is invalid.
public enum NtfyPriority: Int, Sendable, CaseIterable, Codable {
    case min = 1
    case low = 2
    case `default` = 3
    case high = 4
    case max = 5
}
```

`Sources/NtfyKit/Models/NtfyAction.swift`:

```swift
import Foundation

/// One action button attached to a message. ntfy allows at most three.
public struct NtfyAction: Codable, Sendable, Equatable, Identifiable {
    /// Action kinds ntfy defines. `broadcast` is Android-only; it decodes here
    /// so a message containing one is not lost, but the app does not present it.
    public enum Kind: String, Codable, Sendable {
        case view, http, broadcast, copy
    }

    public let id: String
    public let action: Kind
    public let label: String
    public let clear: Bool?

    // view / http
    public let url: String?
    // http
    public let method: String?
    public let headers: [String: String]?
    public let body: String?
    // copy
    public let value: String?
    // broadcast
    public let intent: String?
    public let extras: [String: String]?
}
```

`Sources/NtfyKit/Models/NtfyAttachment.swift`:

```swift
import Foundation

public struct NtfyAttachment: Codable, Sendable, Equatable {
    public let name: String
    public let url: String
    public let type: String?
    public let size: Int?
    public let expires: Int?
}
```

`Sources/NtfyKit/Models/NtfyEvent.swift`:

```swift
import Foundation

/// One decoded line from an ntfy ndjson stream.
///
/// `event` is kept as a raw `String` rather than decoded straight into `Kind`
/// so that an event type introduced by a future server version decodes
/// successfully and is simply ignored, instead of throwing and killing the
/// stream. Callers switch on `kind` and skip `nil`.
public struct NtfyEvent: Codable, Sendable, Equatable {
    public enum Kind: String, Sendable {
        case open
        case message
        case keepalive
        case pollRequest = "poll_request"
    }

    public let id: String
    public let time: Int
    public let expires: Int?
    public let event: String
    public let topic: String
    public let title: String?
    public let message: String?
    public let priority: Int?
    public let tags: [String]?
    public let click: String?
    public let icon: String?
    public let contentType: String?
    public let actions: [NtfyAction]?
    public let attachment: NtfyAttachment?

    public var kind: Kind? { Kind(rawValue: event) }
    public var date: Date { Date(timeIntervalSince1970: TimeInterval(time)) }
    public var resolvedPriority: NtfyPriority { priority.flatMap(NtfyPriority.init(rawValue:)) ?? .default }
    public var isMarkdown: Bool { contentType == "text/markdown" }

    private enum CodingKeys: String, CodingKey {
        case id, time, expires, event, topic, title, message, priority
        case tags, click, icon, actions, attachment
        case contentType = "content_type"
    }
}
```

- [ ] **Step 5: Run to verify it passes**

```bash
swift test --filter NtfyEventDecodingTests 2>&1 | tail -20
```

Expected: PASS, 7 tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/NtfyKit/Models Tests/NtfyKitTests
git commit -m "feat: ntfy wire models with forward-compatible event decoding"
```

---

### Task 3: Line decoder

Separates "is this a valid JSON object" from "is this an event we act on", so a single malformed line can be skipped without tearing down a connection.

**Files:**
- Create: `Sources/NtfyKit/Networking/NtfyEventDecoder.swift`
- Create: `Tests/NtfyKitTests/NtfyEventDecoderTests.swift`

**Interfaces:**
- Consumes: `NtfyEvent` from Task 2.
- Produces: `NtfyEventDecoder` with `func decode(line: String) -> NtfyEventDecoder.Outcome`, and `Outcome` with cases `.event(NtfyEvent)`, `.ignoredUnknownEvent(String)`, `.empty`, `.malformed(line: String, error: String)`.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import NtfyKit

private let decoder = NtfyEventDecoder()

@Test func decodesAValidLineToAnEvent() {
    guard case .event(let e) = decoder.decode(line: Fixtures.minimalMessage) else {
        Issue.record("expected .event"); return
    }
    #expect(e.id == "J7rfOekQUOkP")
}

@Test func reportsUnknownEventTypesSeparately() {
    guard case .ignoredUnknownEvent(let name) = decoder.decode(line: Fixtures.unknownEvent) else {
        Issue.record("expected .ignoredUnknownEvent"); return
    }
    #expect(name == "some_future_event")
}

@Test func treatsBlankLinesAsEmpty() {
    #expect(decoder.decode(line: "") == .empty)
    #expect(decoder.decode(line: "   \t ") == .empty)
}

/// A truncated or corrupt line must be reported, never thrown — the stream
/// stays alive and the caller logs the skip.
@Test func reportsMalformedLinesWithoutThrowing() {
    guard case .malformed(let line, _) = decoder.decode(line: #"{"id":"a","tim"#) else {
        Issue.record("expected .malformed"); return
    }
    #expect(line.hasPrefix("{"))
}

@Test func reportsValidJsonMissingRequiredFieldsAsMalformed() {
    guard case .malformed = decoder.decode(line: #"{"hello":"world"}"#) else {
        Issue.record("expected .malformed"); return
    }
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
swift test --filter NtfyEventDecoderTests 2>&1 | tail -20
```

Expected: FAIL — `cannot find 'NtfyEventDecoder' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Decodes a single ndjson line. Never throws: a bad line is data to report,
/// not a reason to tear down a live connection.
public struct NtfyEventDecoder: Sendable {
    public enum Outcome: Sendable, Equatable {
        case event(NtfyEvent)
        case ignoredUnknownEvent(String)
        case empty
        case malformed(line: String, error: String)
    }

    private let json = JSONDecoder()

    public init() {}

    public func decode(line: String) -> Outcome {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }

        do {
            let event = try json.decode(NtfyEvent.self, from: Data(trimmed.utf8))
            guard event.kind != nil else { return .ignoredUnknownEvent(event.event) }
            return .event(event)
        } catch {
            return .malformed(line: trimmed, error: String(describing: error))
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

```bash
swift test --filter NtfyEventDecoderTests 2>&1 | tail -20
```

Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/NtfyKit/Networking/NtfyEventDecoder.swift Tests/NtfyKitTests/NtfyEventDecoderTests.swift
git commit -m "feat: ndjson line decoder that skips bad lines without failing the stream"
```

---

### Task 4: `SinceParameter` and `WatermarkResolver`

Implements spec §5.1. This is the most subtle logic in the plan; read that section before starting.

**Files:**
- Create: `Sources/NtfyKit/Networking/SinceParameter.swift`, `Sources/NtfyKit/Networking/WatermarkResolver.swift`
- Create: `Tests/NtfyKitTests/SinceParameterTests.swift`, `Tests/NtfyKitTests/WatermarkResolverTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `SinceParameter` enum: `.all`, `.unixTime(Int)`, `.messageID(String)`, `.duration(String)`, each with `var queryValue: String`.
  - `TopicWatermark` struct: `topic: String`, `lastMessageTime: Date?`.
  - `WatermarkResolver.Resolution` struct: `since: SinceParameter`, `hasHistoryGap: Bool`.
  - `WatermarkResolver.resolve(watermarks:cacheWindow:now:margin:) -> Resolution`.

- [ ] **Step 1: Write the failing tests**

`Tests/NtfyKitTests/SinceParameterTests.swift`:

```swift
import Testing
@testable import NtfyKit

@Test func encodesQueryValues() {
    #expect(SinceParameter.all.queryValue == "all")
    #expect(SinceParameter.unixTime(1_788_353_322).queryValue == "1788353322")
    #expect(SinceParameter.messageID("J7rfOekQUOkP").queryValue == "J7rfOekQUOkP")
    #expect(SinceParameter.duration("48h").queryValue == "48h")
}
```

`Tests/NtfyKitTests/WatermarkResolverTests.swift`:

```swift
import Foundation
import Testing
@testable import NtfyKit

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let window: TimeInterval = 12 * 3600

private func wm(_ topic: String, _ offset: TimeInterval?) -> TopicWatermark {
    TopicWatermark(topic: topic, lastMessageTime: offset.map { now.addingTimeInterval($0) })
}

/// No watermark anywhere: a fresh install must not replay the world.
@Test func resolvesToAllWhenNothingHasAWatermark() {
    let r = WatermarkResolver.resolve(watermarks: [wm("a", nil), wm("b", nil)], cacheWindow: window, now: now)
    #expect(r.since == .all)
    #expect(r.hasHistoryGap == false)
}

/// The oldest watermark wins, minus the boundary margin.
@Test func resolvesToTheOldestWatermarkMinusMargin() {
    let r = WatermarkResolver.resolve(
        watermarks: [wm("a", -600), wm("b", -120)],
        cacheWindow: window, now: now, margin: 5
    )
    #expect(r.since == .unixTime(Int(now.timeIntervalSince1970) - 600 - 5))
}

/// A topic with no watermark yet is backfilled separately (spec §5). It must
/// not drag the shared minimum to zero and replay every other topic.
@Test func ignoresTopicsThatHaveNoWatermarkYet() {
    let r = WatermarkResolver.resolve(
        watermarks: [wm("a", -600), wm("new", nil)],
        cacheWindow: window, now: now, margin: 5
    )
    #expect(r.since == .unixTime(Int(now.timeIntervalSince1970) - 600 - 5))
}

/// Older than the server's cache window: the server will silently return the
/// whole cache. The client already knows, and must say so.
@Test func flagsAHistoryGapWhenTheWatermarkPredatesTheCacheWindow() {
    let r = WatermarkResolver.resolve(
        watermarks: [wm("a", -(window + 3600))],
        cacheWindow: window, now: now, margin: 5
    )
    #expect(r.hasHistoryGap == true)
}

/// The boundary sliver: a watermark inside the cache window whose `since`
/// value — watermark minus margin — falls outside it. Measuring the gap from
/// the watermark instead of from the value actually sent reports no gap here.
@Test func flagsAGapWhenTheMarginPushesSinceOutsideTheWindow() {
    let r = WatermarkResolver.resolve(
        watermarks: [wm("a", -(window - 2))],
        cacheWindow: window, now: now, margin: 5
    )
    #expect(r.hasHistoryGap == true)
}

@Test func doesNotFlagAGapForARecentWatermark() {
    let r = WatermarkResolver.resolve(watermarks: [wm("a", -60)], cacheWindow: window, now: now)
    #expect(r.hasHistoryGap == false)
}

@Test func resolvesToAllForAnEmptyTopicSet() {
    let r = WatermarkResolver.resolve(watermarks: [], cacheWindow: window, now: now)
    #expect(r.since == .all)
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
swift test --filter "SinceParameterTests|WatermarkResolverTests" 2>&1 | tail -20
```

Expected: FAIL — `cannot find 'SinceParameter' in scope`.

- [ ] **Step 3: Implement `SinceParameter`**

```swift
import Foundation

/// The `since=` query parameter. Measured behavior (spec §5): a timestamp is a
/// lower bound, a well-formed but unknown message ID silently returns the whole
/// cache, and a malformed value is rejected with HTTP 400 code 40008.
public enum SinceParameter: Sendable, Equatable {
    case all
    case unixTime(Int)
    case messageID(String)
    case duration(String)

    public var queryValue: String {
        switch self {
        case .all: "all"
        case .unixTime(let t): String(t)
        case .messageID(let id): id
        case .duration(let d): d
        }
    }
}
```

- [ ] **Step 4: Implement `WatermarkResolver`**

```swift
import Foundation

/// One topic's resume position on a server.
public struct TopicWatermark: Sendable, Equatable {
    public let topic: String
    /// Server-provided timestamp of the newest message seen. `nil` means this
    /// topic has never been synced and is backfilled separately.
    public let lastMessageTime: Date?

    public init(topic: String, lastMessageTime: Date?) {
        self.topic = topic
        self.lastMessageTime = lastMessageTime
    }
}

/// Computes the single `since=` value for a shared multi-topic connection.
///
/// Timestamps are used rather than message IDs deliberately. Both are correct
/// given deduplication, but an unresolvable message ID returns HTTP 200 with a
/// full cache replay — indistinguishable from a clean resume. A timestamp lets
/// the client detect the same situation before it sends the request, which is
/// what `hasHistoryGap` reports.
public enum WatermarkResolver {
    public struct Resolution: Sendable, Equatable {
        public let since: SinceParameter
        /// True when the oldest watermark predates the server's cache window,
        /// so some messages are unrecoverable and the caller must surface it.
        public let hasHistoryGap: Bool
    }

    public static func resolve(
        watermarks: [TopicWatermark],
        cacheWindow: TimeInterval,
        now: Date = Date(),
        margin: TimeInterval = 5
    ) -> Resolution {
        let times = watermarks.compactMap(\.lastMessageTime)
        guard let oldest = times.min() else {
            return Resolution(since: .all, hasHistoryGap: false)
        }

        // The gap is measured against the value actually sent, which is
        // `oldest - margin`, not against `oldest`. Measuring from `oldest`
        // leaves a margin-wide sliver where the request predates the cache
        // window but the client reports no gap — a false negative in exactly
        // the signal spec section 10 relies on to distinguish a clean resume
        // from a silent full-cache replay.
        let sinceDate = oldest.addingTimeInterval(-margin)
        let gap = now.timeIntervalSince(sinceDate) > cacheWindow
        return Resolution(since: .unixTime(Int(sinceDate.timeIntervalSince1970.rounded(.down))), hasHistoryGap: gap)
    }
}
```

- [ ] **Step 5: Run to verify it passes**

```bash
swift test --filter "SinceParameterTests|WatermarkResolverTests" 2>&1 | tail -20
```

Expected: PASS, 7 tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/NtfyKit/Networking/SinceParameter.swift Sources/NtfyKit/Networking/WatermarkResolver.swift Tests/NtfyKitTests/SinceParameterTests.swift Tests/NtfyKitTests/WatermarkResolverTests.swift
git commit -m "feat: timestamp-based since resolution with history-gap detection"
```

---

### Task 5: `AuthCredential` and `NtfyEndpoint`

**Files:**
- Create: `Sources/NtfyKit/Networking/AuthCredential.swift`, `Sources/NtfyKit/Networking/NtfyEndpoint.swift`
- Create: `Tests/NtfyKitTests/AuthCredentialTests.swift`, `Tests/NtfyKitTests/NtfyEndpointTests.swift`

**Interfaces:**
- Consumes: `SinceParameter` from Task 4.
- Produces:
  - `AuthCredential` enum: `.none`, `.bearer(token: String)`, `.basic(user: String, password: String)`, with `var authorizationHeader: String?`.
  - `NtfyEndpoint` struct with `init(baseURL: URL, credential: AuthCredential)` and methods `streamRequest(topics: [String], since: SinceParameter?) throws -> URLRequest`, `pollRequest(topic: String, since: SinceParameter) throws -> URLRequest`.
  - `NtfyEndpoint.Error` enum: `.noTopics`, `.invalidTopic(String)`.

- [ ] **Step 1: Write the failing tests**

`Tests/NtfyKitTests/AuthCredentialTests.swift`:

```swift
import Foundation
import Testing
@testable import NtfyKit

@Test func noneProducesNoHeader() {
    #expect(AuthCredential.none.authorizationHeader == nil)
}

@Test func bearerProducesABearerHeader() {
    #expect(AuthCredential.bearer(token: "tk_abc").authorizationHeader == "Bearer tk_abc")
}

@Test func basicProducesBase64OfUserColonPassword() {
    let header = AuthCredential.basic(user: "phil", password: "s3cret").authorizationHeader
    #expect(header == "Basic " + Data("phil:s3cret".utf8).base64EncodedString())
}
```

`Tests/NtfyKitTests/NtfyEndpointTests.swift`:

```swift
import Foundation
import Testing
@testable import NtfyKit

private let base = URL(string: "https://ntfy.example.com")!

@Test func buildsAMultiTopicStreamURL() throws {
    let ep = NtfyEndpoint(baseURL: base, credential: .none)
    let req = try ep.streamRequest(topics: ["a", "b", "c"], since: nil)
    #expect(req.url?.absoluteString == "https://ntfy.example.com/a,b,c/json")
}

@Test func appendsSinceWhenPresent() throws {
    let ep = NtfyEndpoint(baseURL: base, credential: .none)
    let req = try ep.streamRequest(topics: ["a"], since: .unixTime(1788353322))
    #expect(req.url?.absoluteString == "https://ntfy.example.com/a/json?since=1788353322")
}

@Test func buildsAOneShotPollURL() throws {
    let ep = NtfyEndpoint(baseURL: base, credential: .none)
    let req = try ep.pollRequest(topic: "a", since: .all)
    #expect(req.url?.absoluteString == "https://ntfy.example.com/a/json?poll=1&since=all")
}

@Test func attachesTheAuthorizationHeader() throws {
    let ep = NtfyEndpoint(baseURL: base, credential: .bearer(token: "tk_abc"))
    let req = try ep.streamRequest(topics: ["a"], since: nil)
    #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer tk_abc")
}

@Test func omitsAuthorizationWhenThereIsNoCredential() throws {
    let ep = NtfyEndpoint(baseURL: base, credential: .none)
    let req = try ep.streamRequest(topics: ["a"], since: nil)
    #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
}

@Test func rejectsAnEmptyTopicList() {
    let ep = NtfyEndpoint(baseURL: base, credential: .none)
    #expect(throws: NtfyEndpoint.Error.noTopics) {
        _ = try ep.streamRequest(topics: [], since: nil)
    }
}

/// A topic containing a comma or slash would silently change which topics are
/// subscribed, so it is rejected rather than escaped.
@Test func rejectsTopicsContainingSeparators() {
    let ep = NtfyEndpoint(baseURL: base, credential: .none)
    #expect(throws: NtfyEndpoint.Error.invalidTopic("a,b")) {
        _ = try ep.streamRequest(topics: ["a,b"], since: nil)
    }
    #expect(throws: NtfyEndpoint.Error.invalidTopic("a/b")) {
        _ = try ep.streamRequest(topics: ["a/b"], since: nil)
    }
}

@Test func preservesABaseURLSubpath() throws {
    let ep = NtfyEndpoint(baseURL: URL(string: "https://example.com/ntfy")!, credential: .none)
    let req = try ep.streamRequest(topics: ["a"], since: nil)
    #expect(req.url?.absoluteString == "https://example.com/ntfy/a/json")
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
swift test --filter "AuthCredentialTests|NtfyEndpointTests" 2>&1 | tail -20
```

Expected: FAIL — `cannot find 'AuthCredential' in scope`.

- [ ] **Step 3: Implement `AuthCredential`**

```swift
import Foundation

/// How to authenticate to one server. Values come from the Keychain and are
/// never persisted in the message store or written to logs.
public enum AuthCredential: Sendable, Equatable {
    case none
    case bearer(token: String)
    case basic(user: String, password: String)

    public var authorizationHeader: String? {
        switch self {
        case .none:
            nil
        case .bearer(let token):
            "Bearer \(token)"
        case .basic(let user, let password):
            "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
        }
    }
}
```

- [ ] **Step 4: Implement `NtfyEndpoint`**

```swift
import Foundation

/// Builds requests against one ntfy server.
public struct NtfyEndpoint: Sendable {
    public enum Error: Swift.Error, Equatable {
        case noTopics
        case invalidTopic(String)
    }

    private let baseURL: URL
    private let credential: AuthCredential

    public init(baseURL: URL, credential: AuthCredential) {
        self.baseURL = baseURL
        self.credential = credential
    }

    /// Long-lived multi-topic stream. ntfy joins topics with commas and tags
    /// each returned message with its own `topic`, so one socket serves many
    /// subscriptions.
    public func streamRequest(topics: [String], since: SinceParameter?) throws -> URLRequest {
        guard !topics.isEmpty else { throw Error.noTopics }
        try topics.forEach(validate)

        var items: [URLQueryItem] = []
        if let since { items.append(URLQueryItem(name: "since", value: since.queryValue)) }
        return request(path: topics.joined(separator: ","), query: items)
    }

    /// One-shot fetch used to backfill a newly added topic.
    public func pollRequest(topic: String, since: SinceParameter) throws -> URLRequest {
        try validate(topic)
        return request(path: topic, query: [
            URLQueryItem(name: "poll", value: "1"),
            URLQueryItem(name: "since", value: since.queryValue),
        ])
    }

    private func validate(_ topic: String) throws {
        guard !topic.isEmpty,
              !topic.contains(","),
              !topic.contains("/"),
              !topic.contains("?")
        else { throw Error.invalidTopic(topic) }
    }

    private func request(path: String, query: [URLQueryItem]) -> URLRequest {
        let url = baseURL.appending(path: path).appending(path: "json")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }

        var req = URLRequest(url: components.url!)
        req.httpMethod = "GET"
        if let header = credential.authorizationHeader {
            req.setValue(header, forHTTPHeaderField: "Authorization")
        }
        return req
    }
}
```

- [ ] **Step 5: Run to verify it passes**

```bash
swift test --filter "AuthCredentialTests|NtfyEndpointTests" 2>&1 | tail -20
```

Expected: PASS, 11 tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/NtfyKit/Networking/AuthCredential.swift Sources/NtfyKit/Networking/NtfyEndpoint.swift Tests/NtfyKitTests/AuthCredentialTests.swift Tests/NtfyKitTests/NtfyEndpointTests.swift
git commit -m "feat: endpoint and credential construction for ntfy servers"
```

---

### Task 6: `BackoffPolicy`

**Files:**
- Create: `Sources/NtfyKit/Networking/BackoffPolicy.swift`
- Create: `Tests/NtfyKitTests/BackoffPolicyTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `BackoffPolicy` struct with `init(base:multiplier:cap:jitterFraction:)`, `static let standard`, and `func delay(forAttempt attempt: Int, randomFraction: () -> Double) -> Duration`.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import NtfyKit

/// Randomness is injected so the schedule is asserted exactly, not sampled.
/// The `@Sendable` annotations are required: a `private let` closure at file
/// scope is global state, which Swift 6 strict concurrency rejects unless the
/// closure type is Sendable. Note this belongs on the test globals only —
/// `BackoffPolicy.delay`'s parameter stays unannotated.
private let noJitter: @Sendable () -> Double = { 0.0 }
private let maxJitter: @Sendable () -> Double = { 1.0 }

@Test func firstAttemptWaitsTheBaseDelay() {
    let p = BackoffPolicy.standard
    #expect(p.delay(forAttempt: 1, randomFraction: noJitter) == .seconds(1))
}

@Test func delayDoublesPerAttempt() {
    let p = BackoffPolicy.standard
    #expect(p.delay(forAttempt: 2, randomFraction: noJitter) == .seconds(2))
    #expect(p.delay(forAttempt: 3, randomFraction: noJitter) == .seconds(4))
    #expect(p.delay(forAttempt: 4, randomFraction: noJitter) == .seconds(8))
}

@Test func delayIsCapped() {
    let p = BackoffPolicy.standard
    #expect(p.delay(forAttempt: 20, randomFraction: noJitter) == .seconds(60))
}

/// Jitter only ever adds, and never pushes past the cap.
@Test func jitterStaysWithinItsFraction() {
    let p = BackoffPolicy.standard
    #expect(p.delay(forAttempt: 3, randomFraction: maxJitter) == .milliseconds(4800))
    #expect(p.delay(forAttempt: 20, randomFraction: maxJitter) == .seconds(60))
}

/// Attempt numbers are 1-based; guard against a caller passing 0 or less.
@Test func nonPositiveAttemptsClampToTheBaseDelay() {
    let p = BackoffPolicy.standard
    #expect(p.delay(forAttempt: 0, randomFraction: noJitter) == .seconds(1))
    #expect(p.delay(forAttempt: -3, randomFraction: noJitter) == .seconds(1))
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
swift test --filter BackoffPolicyTests 2>&1 | tail -20
```

Expected: FAIL — `cannot find 'BackoffPolicy' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Exponential reconnect backoff with additive jitter, capped.
///
/// Jitter is additive rather than symmetric so a delay never falls below the
/// exponential floor, which is what prevents a fleet of clients from
/// synchronising their reconnects after a server restart.
public struct BackoffPolicy: Sendable, Equatable {
    public let base: Duration
    public let multiplier: Double
    public let cap: Duration
    public let jitterFraction: Double

    public static let standard = BackoffPolicy(
        base: .seconds(1), multiplier: 2, cap: .seconds(60), jitterFraction: 0.2
    )

    public init(base: Duration, multiplier: Double, cap: Duration, jitterFraction: Double) {
        self.base = base
        self.multiplier = multiplier
        self.cap = cap
        self.jitterFraction = jitterFraction
    }

    /// - Parameter randomFraction: returns a value in `0...1`. Injected so tests
    ///   can assert the schedule exactly.
    public func delay(forAttempt attempt: Int, randomFraction: () -> Double) -> Duration {
        let steps = Swift.max(0, attempt - 1)
        let baseSeconds = seconds(base)
        let capSeconds = seconds(cap)

        let exponential = Swift.min(baseSeconds * pow(multiplier, Double(steps)), capSeconds)
        let jittered = exponential * (1 + jitterFraction * randomFraction().clamped(to: 0...1))

        return .milliseconds(Int((Swift.min(jittered, capSeconds) * 1000).rounded()))
    }

    private func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
```

- [ ] **Step 4: Run to verify it passes**

```bash
swift test --filter BackoffPolicyTests 2>&1 | tail -20
```

Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/NtfyKit/Networking/BackoffPolicy.swift Tests/NtfyKitTests/BackoffPolicyTests.swift
git commit -m "feat: exponential backoff with additive jitter"
```

---

### Task 7: `KeepaliveWatchdog`

The primary liveness signal (spec §5). A dead TCP connection after sleep frequently goes silent rather than erroring, so the app cannot wait for stream termination.

**Files:**
- Create: `Sources/NtfyKit/Networking/KeepaliveWatchdog.swift`
- Create: `Tests/NtfyKitTests/KeepaliveWatchdogTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `actor KeepaliveWatchdog` with `init(timeout: Duration, sleeper: Sleeper)`, `func start(onTimeout: @Sendable @escaping () async -> Void)`, `func pet()`, `func stop()`. Plus `protocol Sleeper: Sendable { func sleep(for: Duration) async throws }`, `struct SystemSleeper: Sleeper`, and `actor ManualSleeper: Sleeper` (test support, in `NtfyKit` so tests can use it without `@testable` tricks).

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import NtfyKit

@Test func firesWhenNoLineArrivesWithinTheTimeout() async throws {
    let sleeper = ManualSleeper()
    let watchdog = KeepaliveWatchdog(timeout: .seconds(90), sleeper: sleeper)
    let fired = Signal()

    await watchdog.start { await fired.signal() }
    await sleeper.waitForPendingSleep()
    await sleeper.advanceOnePendingSleep()

    #expect(await fired.waitOrTimeout() == true)
}

@Test func doesNotFireWhileLinesKeepArriving() async throws {
    let sleeper = ManualSleeper()
    let watchdog = KeepaliveWatchdog(timeout: .seconds(90), sleeper: sleeper)
    let fired = Signal()

    await watchdog.start { await fired.signal() }
    await sleeper.waitForPendingSleep()
    await watchdog.pet()
    await sleeper.advanceOnePendingSleep()

    #expect(await fired.hasFired == false)
    await watchdog.stop()
}

@Test func stopPreventsAnyFurtherFiring() async throws {
    let sleeper = ManualSleeper()
    let watchdog = KeepaliveWatchdog(timeout: .seconds(90), sleeper: sleeper)
    let fired = Signal()

    await watchdog.start { await fired.signal() }
    await sleeper.waitForPendingSleep()
    await watchdog.stop()
    await sleeper.advanceOnePendingSleep()

    #expect(await fired.hasFired == false)
}

/// Minimal async signal used only by these tests.
actor Signal {
    private(set) var hasFired = false
    func signal() { hasFired = true }
    func waitOrTimeout() async -> Bool {
        for _ in 0..<100 {
            if hasFired { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return hasFired
    }
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
swift test --filter KeepaliveWatchdogTests 2>&1 | tail -20
```

Expected: FAIL — `cannot find 'KeepaliveWatchdog' in scope`.

- [ ] **Step 3: Implement the sleeper abstraction**

In `Sources/NtfyKit/Networking/KeepaliveWatchdog.swift`:

```swift
import Foundation

/// Indirection over `Task.sleep` so timeouts are tested deterministically
/// rather than by waiting out real seconds.
public protocol Sleeper: Sendable {
    func sleep(for duration: Duration) async throws
}

public struct SystemSleeper: Sleeper {
    public init() {}
    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

/// Test sleeper: every `sleep` suspends until `advanceOnePendingSleep()` is called.
///
/// `waitForPendingSleep()` exists to remove a start-order race: the watchdog
/// arms its timer inside a detached `Task`, so a test that advances the sleeper
/// immediately after `start()` can run before any sleep has been registered,
/// advance nothing, and hang. Always wait before advancing.
public actor ManualSleeper: Sleeper {
    private var pending: [CheckedContinuation<Void, Error>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func sleep(for duration: Duration) async throws {
        try await withCheckedThrowingContinuation { continuation in
            pending.append(continuation)
            let toWake = waiters
            waiters.removeAll()
            toWake.forEach { $0.resume() }
        }
    }

    /// Suspends until at least one sleep is registered.
    public func waitForPendingSleep() async {
        guard pending.isEmpty else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Releases the oldest pending sleep, if any.
    public func advanceOnePendingSleep() {
        guard !pending.isEmpty else { return }
        pending.removeFirst().resume()
    }
}
```

- [ ] **Step 4: Implement the watchdog**

Append to the same file:

```swift
/// Fires when no line — message *or* keepalive — has arrived within `timeout`.
///
/// ntfy sends a keepalive roughly every 45s, so the default 90s timeout allows
/// one to be missed before the connection is declared dead.
public actor KeepaliveWatchdog {
    private let timeout: Duration
    private let sleeper: Sleeper

    private var generation = 0
    private var task: Task<Void, Never>?

    public init(timeout: Duration = .seconds(90), sleeper: Sleeper = SystemSleeper()) {
        self.timeout = timeout
        self.sleeper = sleeper
    }

    public func start(onTimeout: @Sendable @escaping () async -> Void) {
        stop()
        arm(onTimeout: onTimeout)
    }

    /// Called for every received line. Restarts the countdown.
    public func pet() {
        guard let handler = currentHandler else { return }
        generation += 1
        task?.cancel()
        arm(onTimeout: handler)
    }

    public func stop() {
        generation += 1
        task?.cancel()
        task = nil
        currentHandler = nil
    }

    private var currentHandler: (@Sendable () async -> Void)?

    private func arm(onTimeout: @Sendable @escaping () async -> Void) {
        currentHandler = onTimeout
        let armed = generation
        task = Task { [timeout, sleeper] in
            do { try await sleeper.sleep(for: timeout) } catch { return }
            await self.fireIfStillArmed(armed)
        }
    }

    private func fireIfStillArmed(_ armed: Int) async {
        guard armed == generation, let handler = currentHandler else { return }
        await handler()
    }
}
```

- [ ] **Step 5: Run to verify it passes**

```bash
swift test --filter KeepaliveWatchdogTests 2>&1 | tail -20
```

Expected: PASS, 3 tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/NtfyKit/Networking/KeepaliveWatchdog.swift Tests/NtfyKitTests/KeepaliveWatchdogTests.swift
git commit -m "feat: keepalive watchdog as the primary liveness signal"
```

---

### Task 8: `MockNtfyServer`

A real loopback HTTP server. Tests for Tasks 9 and 10 run over an actual socket, so streaming, disconnects, and status codes behave as they will in production.

**Files:**
- Create: `Tests/NtfyKitTests/Support/MockNtfyServer.swift`
- Create: `Tests/NtfyKitTests/MockNtfyServerTests.swift`

**Interfaces:**
- Consumes: nothing from `NtfyKit`.
- Produces: `actor MockNtfyServer` with `init()`, `func start() async throws -> URL`, `func stop() async`, `func enqueue(line: String) async`, `func setCloseAfterSending(_:) async`, `func waitForConnection() async`, `func closeCurrentConnection() async`, `func setResponse(status: Int, body: String) async`, and `var receivedRequestPaths: [String]`.

**Framing note.** The server closes the connection after writing its queued
lines by default (`closeAfterSending = true`). Without that, a client reading
with `bytes.lines` never sees end-of-stream and the test hangs rather than
fails. Tests that need a mid-stream drop instead call `setCloseAfterSending(false)`
and then `closeCurrentConnection()` at the moment they choose.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing

@Test func mockServerStreamsEnqueuedLines() async throws {
    let server = MockNtfyServer()
    let base = try await server.start()
    defer { Task { await server.stop() } }

    await server.enqueue(line: #"{"id":"a1","time":1,"event":"open","topic":"t"}"#)
    await server.enqueue(line: #"{"id":"a2","time":2,"event":"message","topic":"t","message":"hi"}"#)

    let url = base.appending(path: "t").appending(path: "json")
    let (bytes, response) = try await URLSession.shared.bytes(from: url)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)

    var lines: [String] = []
    for try await line in bytes.lines { lines.append(line) }
    #expect(lines.count == 2)
    #expect(lines[1].contains("\"message\":\"hi\""))
    #expect(await server.receivedRequestPaths.first?.hasPrefix("/t/json") == true)
}

@Test func mockServerCanReturnAnErrorStatus() async throws {
    let server = MockNtfyServer()
    let base = try await server.start()
    defer { Task { await server.stop() } }

    await server.setResponse(status: 401, body: #"{"code":40101,"error":"unauthorized"}"#)

    let url = base.appending(path: "t").appending(path: "json")
    let (_, response) = try await URLSession.shared.data(from: url)
    #expect((response as? HTTPURLResponse)?.statusCode == 401)
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
swift test --filter MockNtfyServerTests 2>&1 | tail -20
```

Expected: FAIL — `cannot find 'MockNtfyServer' in scope`.

- [ ] **Step 3: Implement the server**

Responses are delimited by connection close rather than `Content-Length` or chunked encoding, which is the simplest framing that supports open-ended streaming and which `URLSession` handles correctly.

```swift
import Foundation
import Network

/// A minimal loopback HTTP server that speaks just enough to imitate ntfy's
/// ndjson streaming endpoint. Binds port 0 so parallel tests never collide.
actor MockNtfyServer {
    private var listener: NWListener?
    private var connection: NWConnection?
    private var pendingLines: [String] = []
    private var status = 200
    private var errorBody: String?
    /// Close the socket once the queued lines are written. Required for a
    /// client using `bytes.lines` to observe end-of-stream at all.
    private var closeAfterSending = true
    private var connectionWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var receivedRequestPaths: [String] = []

    func start() async throws -> URL {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: .any)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] conn in
            Task { await self?.accept(conn) }
        }

        let port: UInt16 = try await withCheckedThrowingContinuation { cont in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    cont.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    cont.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: .global())
        }

        return URL(string: "http://127.0.0.1:\(port)")!
    }

    func stop() {
        connection?.cancel()
        listener?.cancel()
        connection = nil
        listener = nil
    }

    func enqueue(line: String) { pendingLines.append(line) }

    /// Pass `false` to hold the connection open after writing, so a test can
    /// drop it mid-stream with `closeCurrentConnection()`.
    func setCloseAfterSending(_ value: Bool) { closeAfterSending = value }

    /// Suspends until a client has connected.
    func waitForConnection() async {
        guard connection == nil else { return }
        await withCheckedContinuation { connectionWaiters.append($0) }
    }

    func setResponse(status: Int, body: String) {
        self.status = status
        self.errorBody = body
    }

    func closeCurrentConnection() {
        connection?.cancel()
        connection = nil
    }

    private func accept(_ conn: NWConnection) {
        connection = conn
        let toWake = connectionWaiters
        connectionWaiters.removeAll()
        toWake.forEach { $0.resume() }
        conn.start(queue: .global())
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else { return }
            Task { await self.respond(to: request, on: conn) }
        }
    }

    private func respond(to request: String, on conn: NWConnection) {
        if let requestLine = request.split(separator: "\r\n").first {
            let parts = requestLine.split(separator: " ")
            if parts.count >= 2 { receivedRequestPaths.append(String(parts[1])) }
        }

        if let errorBody {
            let head = """
            HTTP/1.1 \(status) Error\r
            Content-Type: application/json\r
            Content-Length: \(errorBody.utf8.count)\r
            Connection: close\r
            \r

            """
            conn.send(content: Data((head + errorBody).utf8), completion: .contentProcessed { _ in
                conn.cancel()
            })
            return
        }

        // No Content-Length: the body is delimited by connection close, which
        // is what makes open-ended streaming possible over HTTP/1.1.
        let head = """
        HTTP/1.1 200 OK\r
        Content-Type: application/x-ndjson\r
        Connection: close\r
        \r

        """
        let body = pendingLines.map { $0 + "\n" }.joined()
        pendingLines.removeAll()
        let shouldClose = closeAfterSending
        conn.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in
            if shouldClose { conn.cancel() }
        })
    }
}
```

- [ ] **Step 4: Run to verify it passes**

```bash
swift test --filter MockNtfyServerTests 2>&1 | tail -20
```

Expected: PASS, 2 tests. If binding fails, that answers the spec's open CI question — see Task 12.

- [ ] **Step 5: Commit**

```bash
git add Tests/NtfyKitTests/Support/MockNtfyServer.swift Tests/NtfyKitTests/MockNtfyServerTests.swift
git commit -m "test: loopback ntfy server for socket-level stream tests"
```

---

### Task 9: `NtfyStreamClient`

**Files:**
- Create: `Sources/NtfyKit/Networking/NtfyStreamClient.swift`
- Create: `Tests/NtfyKitTests/NtfyStreamClientTests.swift`

**Interfaces:**
- Consumes: `NtfyEventDecoder` (Task 3), `NtfyEndpoint` (Task 5).
- Produces: `NtfyStreamClient` struct with `init(session: URLSession = .shared)` and `func stream(_ request: URLRequest) -> AsyncThrowingStream<StreamElement, Swift.Error>`. `StreamElement` enum: `.event(NtfyEvent)`, `.skippedLine(reason: String)`. `NtfyStreamClient.Error` enum: `.unauthorized`, `.rateLimited(retryAfter: TimeInterval?)`, `.invalidSince`, `.httpError(status: Int)`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import NtfyKit

private func endpoint(_ base: URL) -> NtfyEndpoint {
    NtfyEndpoint(baseURL: base, credential: .none)
}

@Test func yieldsDecodedEventsFromTheStream() async throws {
    let server = MockNtfyServer()
    let base = try await server.start()
    defer { Task { await server.stop() } }

    await server.enqueue(line: Fixtures.openEvent)
    await server.enqueue(line: Fixtures.minimalMessage)

    let request = try endpoint(base).streamRequest(topics: ["alerts"], since: nil)
    var kinds: [NtfyEvent.Kind?] = []
    for try await element in NtfyStreamClient().stream(request) {
        if case .event(let e) = element { kinds.append(e.kind) }
    }
    #expect(kinds == [.open, .message])
}

/// A malformed line is reported and skipped; the events around it still arrive.
@Test func skipsMalformedLinesWithoutEndingTheStream() async throws {
    let server = MockNtfyServer()
    let base = try await server.start()
    defer { Task { await server.stop() } }

    await server.enqueue(line: Fixtures.openEvent)
    await server.enqueue(line: #"{"id":"broken"#)
    await server.enqueue(line: Fixtures.minimalMessage)

    let request = try endpoint(base).streamRequest(topics: ["alerts"], since: nil)
    var events = 0
    var skipped = 0
    for try await element in NtfyStreamClient().stream(request) {
        switch element {
        case .event: events += 1
        case .skippedLine: skipped += 1
        }
    }
    #expect(events == 2)
    #expect(skipped == 1)
}

@Test func mapsUnauthorizedToATypedError() async throws {
    let server = MockNtfyServer()
    let base = try await server.start()
    defer { Task { await server.stop() } }
    await server.setResponse(status: 401, body: #"{"code":40101,"error":"unauthorized"}"#)

    let request = try endpoint(base).streamRequest(topics: ["alerts"], since: nil)
    await #expect(throws: NtfyStreamClient.Error.unauthorized) {
        for try await _ in NtfyStreamClient().stream(request) {}
    }
}

/// HTTP 400 code 40008 means the client built a bad `since` value — a bug,
/// not a server condition, so it gets its own case (spec §10).
@Test func mapsInvalidSinceToATypedError() async throws {
    let server = MockNtfyServer()
    let base = try await server.start()
    defer { Task { await server.stop() } }
    await server.setResponse(status: 400, body: #"{"code":40008,"error":"invalid since parameter"}"#)

    let request = try endpoint(base).streamRequest(topics: ["alerts"], since: nil)
    await #expect(throws: NtfyStreamClient.Error.invalidSince) {
        for try await _ in NtfyStreamClient().stream(request) {}
    }
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
swift test --filter NtfyStreamClientTests 2>&1 | tail -20
```

Expected: FAIL — `cannot find 'NtfyStreamClient' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Turns a long-lived ndjson HTTP response into a stream of decoded events.
public struct NtfyStreamClient: Sendable {
    public enum StreamElement: Sendable {
        case event(NtfyEvent)
        /// A line that could not be used. Carries a reason for logging; the
        /// stream continues. Never contains a message body.
        case skippedLine(reason: String)
    }

    public enum Error: Swift.Error, Equatable {
        case unauthorized
        case rateLimited(retryAfter: TimeInterval?)
        case invalidSince
        case httpError(status: Int)
    }

    private let session: URLSession
    private let decoder = NtfyEventDecoder()

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func stream(_ request: URLRequest) -> AsyncThrowingStream<StreamElement, Swift.Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    if let error = Self.error(for: response) { throw error }

                    for try await line in bytes.lines {
                        switch decoder.decode(line: line) {
                        case .event(let event):
                            continuation.yield(.event(event))
                        case .ignoredUnknownEvent(let name):
                            continuation.yield(.skippedLine(reason: "unknown event type: \(name)"))
                        case .malformed(_, let error):
                            // The line itself is deliberately not included: it
                            // may contain a message body (spec §9).
                            continuation.yield(.skippedLine(reason: "malformed line: \(error)"))
                        case .empty:
                            continue
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func error(for response: URLResponse) -> Error? {
        guard let http = response as? HTTPURLResponse else { return nil }
        switch http.statusCode {
        case 200..<300:
            return nil
        case 401, 403:
            return .unauthorized
        case 429:
            let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
            return .rateLimited(retryAfter: retryAfter)
        case 400:
            // ntfy returns code 40008 for a malformed `since`; treat any 400 on
            // a subscribe request as that, since it is the only 400 we can cause.
            return .invalidSince
        default:
            return .httpError(status: http.statusCode)
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

```bash
swift test --filter NtfyStreamClientTests 2>&1 | tail -20
```

Expected: PASS, 4 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/NtfyKit/Networking/NtfyStreamClient.swift Tests/NtfyKitTests/NtfyStreamClientTests.swift
git commit -m "feat: ndjson stream client with typed HTTP error mapping"
```

---

### Task 10: `ConnectionState` and `ServerConnection`

Ties Tasks 3–9 together into the actor that owns one server's connection.

**Files:**
- Create: `Sources/NtfyKit/Networking/ConnectionState.swift`, `Sources/NtfyKit/Networking/ServerConnection.swift`
- Create: `Tests/NtfyKitTests/ServerConnectionTests.swift`

**Interfaces:**
- Consumes: `NtfyEndpoint`, `NtfyStreamClient`, `BackoffPolicy`, `KeepaliveWatchdog`, `Sleeper`, `WatermarkResolver`, `TopicWatermark`.
- Produces: `ConnectionState` enum (`.idle`, `.connecting`, `.open`, `.degraded(reason: String)`, `.backoff(attempt: Int)`, `.unauthorized`); `actor ServerConnection` with `init(endpoint:topics:watermarks:client:backoff:sleeper:watchdogTimeout:)`, `func start()`, `func stop()`, `func reconnectNow()`, `var state: ConnectionState`, and `var events: AsyncStream<NtfyEvent>`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import NtfyKit

private func makeConnection(
    base: URL,
    topics: [String] = ["alerts"],
    sleeper: Sleeper = ManualSleeper()
) -> ServerConnection {
    ServerConnection(
        endpoint: NtfyEndpoint(baseURL: base, credential: .none),
        topics: topics,
        watermarks: [TopicWatermark(topic: "alerts", lastMessageTime: nil)],
        client: NtfyStreamClient(),
        backoff: .standard,
        sleeper: sleeper
    )
}

@Test func reachesOpenStateAndEmitsMessages() async throws {
    let server = MockNtfyServer()
    let base = try await server.start()
    defer { Task { await server.stop() } }

    await server.enqueue(line: Fixtures.openEvent)
    await server.enqueue(line: Fixtures.minimalMessage)

    let connection = makeConnection(base: base)
    var received: [NtfyEvent] = []
    let collector = Task {
        for await event in connection.events where event.kind == .message {
            received.append(event)
            break
        }
    }

    await connection.start()
    _ = await collector.value

    #expect(received.count == 1)
    #expect(await connection.state == .open)
    await connection.stop()
}

/// The subscribe URL must name every topic, comma-joined, on one connection.
@Test func subscribesToAllTopicsOnASingleConnection() async throws {
    let server = MockNtfyServer()
    let base = try await server.start()
    defer { Task { await server.stop() } }
    await server.enqueue(line: Fixtures.openEvent)

    let connection = makeConnection(base: base, topics: ["alerts", "deploys", "cron"])
    await connection.start()
    try await Task.sleep(for: .milliseconds(300))

    let path = await server.receivedRequestPaths.first ?? ""
    #expect(path.hasPrefix("/alerts,deploys,cron/json"))
    await connection.stop()
}

/// A 401 stops retrying entirely rather than hammering the server (spec §10).
@Test func stopsRetryingAfterUnauthorized() async throws {
    let server = MockNtfyServer()
    let base = try await server.start()
    defer { Task { await server.stop() } }
    await server.setResponse(status: 401, body: #"{"code":40101,"error":"unauthorized"}"#)

    let connection = makeConnection(base: base)
    await connection.start()
    try await Task.sleep(for: .milliseconds(300))

    #expect(await connection.state == .unauthorized)
    #expect(await server.receivedRequestPaths.count == 1)
    await connection.stop()
}

/// After the server drops the connection, the actor enters backoff rather than
/// giving up or spinning.
@Test func entersBackoffWhenTheStreamEnds() async throws {
    let server = MockNtfyServer()
    let base = try await server.start()
    defer { Task { await server.stop() } }
    await server.enqueue(line: Fixtures.openEvent)

    let sleeper = ManualSleeper()
    let connection = makeConnection(base: base, sleeper: sleeper)
    await connection.start()
    // The server closes after writing, so the stream ends on its own.
    try await Task.sleep(for: .milliseconds(500))

    if case .backoff = await connection.state {} else {
        Issue.record("expected .backoff, got \(await connection.state)")
    }
    await connection.stop()
}

/// reconnectNow() is what sleep/wake and network-path changes call: it must
/// skip the pending backoff delay instead of waiting it out (spec §5).
@Test func reconnectNowBypassesTheBackoffDelay() async throws {
    let server = MockNtfyServer()
    let base = try await server.start()
    defer { Task { await server.stop() } }
    await server.enqueue(line: Fixtures.openEvent)

    let sleeper = ManualSleeper()
    let connection = makeConnection(base: base, sleeper: sleeper)
    await connection.start()
    try await Task.sleep(for: .milliseconds(500))

    await server.enqueue(line: Fixtures.openEvent)
    await connection.reconnectNow()
    try await Task.sleep(for: .milliseconds(300))

    #expect(await server.receivedRequestPaths.count >= 2)
    await connection.stop()
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
swift test --filter ServerConnectionTests 2>&1 | tail -20
```

Expected: FAIL — `cannot find 'ServerConnection' in scope`.

- [ ] **Step 3: Implement `ConnectionState`**

```swift
import Foundation

/// Observable state of one server's connection. Drives the menu bar icon.
public enum ConnectionState: Sendable, Equatable {
    case idle
    case connecting
    case open
    case degraded(reason: String)
    case backoff(attempt: Int)
    /// Terminal until credentials change: retrying a rejected credential only
    /// burns rate limit.
    case unauthorized
}
```

- [ ] **Step 4: Implement `ServerConnection`**

```swift
import Foundation

/// Owns one long-lived connection to one server, covering every subscribed
/// topic on that server (spec §5).
public actor ServerConnection {
    public private(set) var state: ConnectionState = .idle

    private let endpoint: NtfyEndpoint
    private let topics: [String]
    private var watermarks: [TopicWatermark]
    private let client: NtfyStreamClient
    private let backoff: BackoffPolicy
    private let sleeper: Sleeper
    private let watchdog: KeepaliveWatchdog
    private let cacheWindow: TimeInterval

    private var runTask: Task<Void, Never>?
    private var attempt = 0

    /// Created eagerly in `init`, not lazily on first access. A lazy stream
    /// leaves `continuation` nil until something reads `events`, so any message
    /// arriving before the first read is silently dropped — and whether that
    /// happens depends on task scheduling. `AsyncStream` buffers by default, so
    /// an eager stream loses nothing.
    private let continuation: AsyncStream<NtfyEvent>.Continuation
    public nonisolated let events: AsyncStream<NtfyEvent>

    public init(
        endpoint: NtfyEndpoint,
        topics: [String],
        watermarks: [TopicWatermark],
        client: NtfyStreamClient = NtfyStreamClient(),
        backoff: BackoffPolicy = .standard,
        sleeper: Sleeper = SystemSleeper(),
        watchdogTimeout: Duration = .seconds(90),
        cacheWindow: TimeInterval = 12 * 3600
    ) {
        var capturedContinuation: AsyncStream<NtfyEvent>.Continuation!
        self.events = AsyncStream { capturedContinuation = $0 }
        self.continuation = capturedContinuation

        self.endpoint = endpoint
        self.topics = topics
        self.watermarks = watermarks
        self.client = client
        self.backoff = backoff
        self.sleeper = sleeper
        self.watchdog = KeepaliveWatchdog(timeout: watchdogTimeout, sleeper: sleeper)
        self.cacheWindow = cacheWindow
    }

    public func start() {
        guard runTask == nil else { return }
        runTask = Task { await self.runLoop() }
    }

    public func stop() async {
        runTask?.cancel()
        runTask = nil
        await watchdog.stop()
        state = .idle
    }

    /// Called on wake from sleep and when the network path becomes satisfied.
    /// Cancels any pending backoff so the reconnect is immediate.
    public func reconnectNow() {
        guard state != .unauthorized else { return }
        attempt = 0
        runTask?.cancel()
        runTask = Task { await self.runLoop() }
    }

    private func runLoop() async {
        while !Task.isCancelled {
            do {
                try await connectOnce()
                // A clean end of stream is still a disconnect; back off and retry.
                guard !Task.isCancelled else { return }
                await waitBeforeRetry()
            } catch NtfyStreamClient.Error.unauthorized {
                state = .unauthorized
                await watchdog.stop()
                return
            } catch NtfyStreamClient.Error.rateLimited(let retryAfter) {
                state = .degraded(reason: "rate limited")
                try? await sleeper.sleep(for: .seconds(Int(retryAfter ?? 60)))
            } catch {
                guard !Task.isCancelled else { return }
                state = .degraded(reason: String(describing: error))
                await waitBeforeRetry()
            }
        }
    }

    private func connectOnce() async throws {
        state = .connecting

        let resolution = WatermarkResolver.resolve(watermarks: watermarks, cacheWindow: cacheWindow)
        if resolution.hasHistoryGap {
            // Surfaced rather than swallowed: the server will replay its whole
            // cache and some messages are simply unrecoverable (spec §10).
            state = .degraded(reason: "history gap: watermark predates server cache")
        }

        let request = try endpoint.streamRequest(topics: topics, since: resolution.since)

        await watchdog.start { [weak self] in
            await self?.handleWatchdogTimeout()
        }
        defer { Task { await watchdog.stop() } }

        for try await element in client.stream(request) {
            await watchdog.pet()
            guard case .event(let event) = element else { continue }

            switch event.kind {
            case .open:
                state = .open
                attempt = 0
            case .message:
                record(event)
                continuation.yield(event)
            case .keepalive, .pollRequest, nil:
                continue
            }
        }
    }

    private func record(_ event: NtfyEvent) {
        guard let index = watermarks.firstIndex(where: { $0.topic == event.topic }) else { return }
        let existing = watermarks[index].lastMessageTime
        guard existing == nil || event.date > existing! else { return }
        watermarks[index] = TopicWatermark(topic: event.topic, lastMessageTime: event.date)
    }

    private func handleWatchdogTimeout() {
        state = .degraded(reason: "no keepalive within timeout")
        runTask?.cancel()
        runTask = Task { await self.runLoop() }
    }

    private func waitBeforeRetry() async {
        attempt += 1
        state = .backoff(attempt: attempt)
        let delay = backoff.delay(forAttempt: attempt, randomFraction: { Double.random(in: 0...1) })
        try? await sleeper.sleep(for: delay)
    }
}
```

- [ ] **Step 5: Run to verify it passes**

```bash
swift test --filter ServerConnectionTests 2>&1 | tail -20
```

Expected: PASS, 5 tests. If a timing-sensitive test is flaky, lengthen the `Task.sleep` in that test rather than weakening the assertion.

- [ ] **Step 6: Commit**

```bash
git add Sources/NtfyKit/Networking/ConnectionState.swift Sources/NtfyKit/Networking/ServerConnection.swift Tests/NtfyKitTests/ServerConnectionTests.swift
git commit -m "feat: per-server connection actor with watchdog and backoff"
```

---

### Task 11: `KeychainStore`

**Files:**
- Create: `Sources/NtfyKit/Security/KeychainStore.swift`
- Create: `Tests/NtfyKitTests/KeychainStoreTests.swift`

**Interfaces:**
- Consumes: `AuthCredential` (Task 5).
- Produces: `KeychainStore` struct with `init(service: String)`, `func save(_ credential: AuthCredential, forServer id: UUID) throws`, `func load(forServer id: UUID) throws -> AuthCredential`, `func delete(forServer id: UUID) throws`. `KeychainStore.Error` enum: `.unhandled(status: OSStatus)`, `.malformedData`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import NtfyKit

/// A per-run service name keeps tests from colliding with each other or with a
/// real installed app's keychain items.
private func makeStore() -> KeychainStore {
    KeychainStore(service: "dev.aloi.NtfyMe.tests.\(UUID().uuidString)")
}

@Test func returnsNoneWhenNothingIsStored() throws {
    let store = makeStore()
    #expect(try store.load(forServer: UUID()) == .none)
}

@Test func roundTripsABearerToken() throws {
    let store = makeStore()
    let id = UUID()
    try store.save(.bearer(token: "tk_abc123"), forServer: id)
    #expect(try store.load(forServer: id) == .bearer(token: "tk_abc123"))
    try store.delete(forServer: id)
}

@Test func roundTripsBasicCredentials() throws {
    let store = makeStore()
    let id = UUID()
    try store.save(.basic(user: "phil", password: "s3cret"), forServer: id)
    #expect(try store.load(forServer: id) == .basic(user: "phil", password: "s3cret"))
    try store.delete(forServer: id)
}

@Test func savingTwiceOverwritesRatherThanDuplicating() throws {
    let store = makeStore()
    let id = UUID()
    try store.save(.bearer(token: "first"), forServer: id)
    try store.save(.bearer(token: "second"), forServer: id)
    #expect(try store.load(forServer: id) == .bearer(token: "second"))
    try store.delete(forServer: id)
}

@Test func deleteRemovesTheCredential() throws {
    let store = makeStore()
    let id = UUID()
    try store.save(.bearer(token: "tk"), forServer: id)
    try store.delete(forServer: id)
    #expect(try store.load(forServer: id) == .none)
}

@Test func deletingSomethingAbsentIsNotAnError() throws {
    let store = makeStore()
    try store.delete(forServer: UUID())
}

@Test func savingNoneClearsAnyStoredCredential() throws {
    let store = makeStore()
    let id = UUID()
    try store.save(.bearer(token: "tk"), forServer: id)
    try store.save(.none, forServer: id)
    #expect(try store.load(forServer: id) == .none)
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
swift test --filter KeychainStoreTests 2>&1 | tail -20
```

Expected: FAIL — `cannot find 'KeychainStore' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation
import Security

/// Stores one credential per server in the login keychain.
///
/// Credentials live only here — never in the message store, never in an export,
/// never in a log (spec §9). The account name is the server's UUID, so nothing
/// identifying the server's hostname is written either.
public struct KeychainStore: Sendable {
    public enum Error: Swift.Error, Equatable {
        case unhandled(status: OSStatus)
        case malformedData
    }

    private let service: String

    public init(service: String = "dev.aloi.NtfyMe") {
        self.service = service
    }

    public func save(_ credential: AuthCredential, forServer id: UUID) throws {
        guard let payload = Self.encode(credential) else {
            try delete(forServer: id)
            return
        }

        try delete(forServer: id)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecValueData as String: payload,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw Error.unhandled(status: status) }
    }

    public func load(forServer id: UUID) throws -> AuthCredential {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecItemNotFound:
            return .none
        case errSecSuccess:
            guard let data = result as? Data else { throw Error.malformedData }
            guard let credential = Self.decode(data) else { throw Error.malformedData }
            return credential
        default:
            throw Error.unhandled(status: status)
        }
    }

    public func delete(forServer id: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Error.unhandled(status: status)
        }
    }

    // MARK: - Encoding

    private struct Stored: Codable {
        let kind: String
        let a: String
        let b: String?
    }

    private static func encode(_ credential: AuthCredential) -> Data? {
        let stored: Stored
        switch credential {
        case .none:
            return nil
        case .bearer(let token):
            stored = Stored(kind: "bearer", a: token, b: nil)
        case .basic(let user, let password):
            stored = Stored(kind: "basic", a: user, b: password)
        }
        return try? JSONEncoder().encode(stored)
    }

    private static func decode(_ data: Data) -> AuthCredential? {
        guard let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return nil }
        switch stored.kind {
        case "bearer":
            return .bearer(token: stored.a)
        case "basic":
            guard let password = stored.b else { return nil }
            return .basic(user: stored.a, password: password)
        default:
            return nil
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

```bash
swift test --filter KeychainStoreTests 2>&1 | tail -20
```

Expected: PASS, 7 tests. If macOS prompts for keychain access, allow it — SwiftPM test binaries are not signed with a stable identity, which is expected here and does not affect the shipping app.

- [ ] **Step 5: Commit**

```bash
git add Sources/NtfyKit/Security/KeychainStore.swift Tests/NtfyKitTests/KeychainStoreTests.swift
git commit -m "feat: keychain-backed credential storage keyed by server UUID"
```

---

### Task 12: CI, and resolving the spec's open assumption

**Files:**
- Create: `.github/workflows/ci.yml`
- Modify: `docs/superpowers/specs/2026-09-02-mac-ntfy-design.md` — the "Unverified assumption" paragraph in §11
- Modify: `README.md` — add a build-status and development section

**Interfaces:**
- Consumes: everything above.
- Produces: a green CI run, and a spec whose §11 states a measured fact rather than an assumption.

- [ ] **Step 1: Write the workflow**

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  test:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4

      - name: Show toolchain
        run: swift --version

      - name: Build
        run: swift build -v

      - name: Test
        run: swift test -v
```

No signing secrets are configured, and none may be added: the repository is public.

- [ ] **Step 2: Push and observe the run**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: build and test on macOS runners"
git push
gh run watch
```

- [ ] **Step 3: Resolve the loopback question**

The spec records an unverified assumption: that an unsigned test binary on a hosted macOS runner can bind loopback for `MockNtfyServer`.

- **If the Task 8–10 tests pass in CI:** replace the "Unverified assumption" paragraph in §11 with a statement that it was confirmed on `macos-15` on the run's date, and delete the ad-hoc-signing fallback sentence.
- **If they fail with a permission or binding error:** add a CI step that ad-hoc signs the test bundle (`codesign -s - --force`) before `swift test`, confirm it goes green, and rewrite the paragraph to record what was actually required.

Either way the paragraph must stop saying "unverified."

- [ ] **Step 4: Verify the full suite passes locally too**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test 2>&1 | tail -30
```

Expected: all tests pass — 57 tests across 13 test files.

- [ ] **Step 5: Confirm the public-repo constraint holds**

Nothing personal or secret may have crept into a fixture or a test name:

```bash
git grep -inE "vaspian|aloi\.dev/|tk_[A-Za-z0-9]{8}|10\.[0-9]+\.[0-9]+\.[0-9]+" -- . ':!docs/' || echo "clean"
```

Expected: `clean`. Any hit must be sanitized before this task is considered done. (`docs/` is excluded because the spec legitimately discusses the `aloi.dev`-derived bundle identifier.)

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "docs: record measured CI loopback behavior, closing the spec's open assumption"
```

---

## Definition of Done for Stages 1–2

- `Scripts/build-app.sh` produces a signed `NtfyMe.app` that launches and shows a menu bar item.
- `swift test` passes locally and in CI.
- `NtfyKit` imports no UI framework.
- A `ServerConnection` pointed at a real ntfy server streams messages, survives a server-side disconnect, and stops retrying on 401.
- No credential, personal topic, internal hostname, or signing material exists anywhere in the repository.
- The spec's §11 CI assumption is resolved into a measured statement.

## Deferred from spec §5: `ConnectionCoordinator`

Spec §5 describes a `ConnectionCoordinator` that owns one `ServerConnection` per
server and drives reconnects from `NSWorkspace.didWakeNotification` and
`NWPathMonitor`. It is **not** in this plan, for a reason worth stating: it
needs `NSWorkspace`, which is AppKit, and a Global Constraint of this plan is
that `NtfyKit` imports no UI framework.

The seam already exists. `ServerConnection.reconnectNow()` (Task 10) is exactly
the entry point the coordinator will call, and Task 10 tests that it bypasses
the pending backoff — which is the whole behavioral requirement. The coordinator
itself is a thin fan-out over that method and lands in Plan 3 alongside the
other app-target code.

If a later reviewer wants the coordinator in `NtfyKit`, the split is: the
`NWPathMonitor` half can live in the library (Network.framework is not UI), the
`NSWorkspace` half cannot. That is not worth two types today.

## What this plan deliberately does not build

Stage 3 and later, each getting its own plan once the stage before it lands:

- **Plan 2 (Stage 3):** SwiftData store, `uniqueKey` dedupe, watermark persistence, new-topic backfill, retention pruning.
- **Plan 3 (Stage 4):** `ConnectionCoordinator` with sleep/wake and network-path
  triggers, notification presentation, menu bar popover, History window, Settings.
- **Plan 4 (Stage 5):** compose sheet, attachment upload, Developer ID signing and notarization.
