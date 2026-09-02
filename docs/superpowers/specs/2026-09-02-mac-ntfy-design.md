# Ntfy Bar — a native macOS client for ntfy

**Status:** design approved, pending spec review
**Date:** 2026-09-02

## 1. Purpose

A first-class native macOS app for watching [ntfy](https://ntfy.sh) subscriptions.
It lives in the menu bar, delivers native notifications, and keeps a searchable
local archive of every message it has seen.

The app is **open source**. Nothing about the author's own servers, topics, or
credentials is baked into the source tree. A fresh clone starts with an empty
server list and an onboarding flow.

### Goals

- Cover the ntfy feature set: subscribe, publish, priorities, tags, markdown,
  click URLs, action buttons, attachments, icons, scheduled delivery, auth.
- Feel like a Mac app built in 2026: SF Symbols, `NavigationSplitView`, the
  standard Settings scene, full keyboard navigation, VoiceOver, Dark Mode.
- Survive a laptop. Sleep, wake, network changes, and dead-but-not-closed
  sockets must not silently stop delivery.
- Be the durable record. ntfy.sh caches roughly 12 hours; the local store is
  the source of truth and the server is only a gap-filler.

### Non-goals

- iOS or iPadOS.
- Running an ntfy server.
- Sync between Macs. The local store is per-machine.

## 2. Naming and identity

| Item | Value | Notes |
|---|---|---|
| Product name | Ntfy Bar | **Review item** — easy to change now, painful later |
| Bundle identifier | `com.github.ctaloi.NtfyBar` | **Review item** — forks must change this |
| License | MIT | **Review item** |

Bundle identifier is a build variable (`PRODUCT_BUNDLE_ID`) with the above as
its default, so a fork can rebrand without editing sources.

## 3. Architecture

Three SwiftPM targets:

- **`NtfyKit`** (library) — models, REST client, streaming client, connection
  state machine, Keychain access, retention. No AppKit, no SwiftUI. This is
  where the interesting logic lives and where the tests point.
- **`NtfyApp`** (executable) — menu bar, windows, notification presentation.
  Thin; it renders `NtfyKit` state.
- **`NtfyKitTests`** — unit tests plus `MockNtfyServer`, a loopback HTTP server
  that streams canned newline-delimited JSON including keepalives and
  mid-stream disconnects.

### Rejected alternatives

**Thin client, server as source of truth.** No local database; fetch
`?poll=1&since=…` when the history window opens. Rejected: ntfy.sh caches
about 12 hours, so "history" would mean "since yesterday, maybe."

**LaunchAgent daemon plus separate UI app.** A background XPC service owns the
connections; the UI attaches to it. Genuinely more robust — the connection
survives a UI crash — but it costs two bundles, XPC plumbing, and two
notarization targets. An `LSUIElement` menu bar app is already always-running,
so the additional robustness is marginal. Over-engineered for this app.

## 4. Data model (SwiftData)

### `Server`

`id: UUID`, `name: String`, `baseURL: URL`, `authKind: {none, token, basic}`,
`sortOrder: Int`, `subscriptions: [Subscription]` (cascade delete).

**Credentials are never stored here.** They live in the Keychain, keyed by the
server UUID. See §9.

### `Subscription`

`id: UUID`, `topic: String`, `displayName: String?`, `server: Server`,
`lastMessageID: String?`, `lastMessageTime: Date?`, `muted: Bool`,
`minAlertPriority: Int` (1–5), `symbolName: String?`, `accentColor: String?`.

`lastMessageID` / `lastMessageTime` form the per-topic watermark that drives
replay on reconnect. `minAlertPriority` lets a chatty topic be recorded without
raising a banner for every message.

### `Message`

Mirrors the ntfy message JSON:

`uniqueKey: String` (`@Attribute(.unique)`, formatted `"{serverID}/{topic}/{id}"`),
`messageID: String`, `topic: String`, `serverID: UUID`, `subscription: Subscription?`,
`time: Date`, `expires: Date?`, `title: String?`, `body: String`, `priority: Int`,
`tags: [String]`, `click: URL?`, `iconURL: URL?`, `contentType: String?`,
`actionsJSON: Data?`, `attachment: Attachment?`, `isRead: Bool`.

`uniqueKey` is what makes replay-on-reconnect safe: overlapping windows
upsert rather than duplicate. The store actor queries existing keys for a batch
before inserting rather than relying solely on unique-constraint upsert
semantics.

`contentType == "text/markdown"` selects markdown rendering.

### `Attachment`

`name`, `url`, `type`, `size`, `expires`, `localFilename: String?`.

Downloaded files live in `~/Library/Application Support/{bundleID}/Attachments/`,
outside the database, so pruning reclaims real disk.

### Action representation

ntfy actions decode to a `NtfyAction` value type — `id`, `action`
(`view`/`http`/`broadcast`/`copy`), `label`, `clear`, plus type-specific fields
(`url`, `method`, `headers`, `body`, `value`, `intent`, `extras`). Persisted as
JSON in `actionsJSON`.

## 5. Connection layer

### Transport

Newline-delimited JSON over a long-lived `GET`, read with
`URLSession.bytes(for:)` and `.lines`. Chosen over `/sse` (extra framing to
parse for no gain) and `/ws` (bidirectionality this app does not need, plus
manual ping handling).

### One connection per server, not per topic

ntfy accepts comma-separated topics on a single stream:

```
GET {baseURL}/{topic1},{topic2},{topic3}/json?since={watermark}
```

Verified against ntfy.sh on 2026-09-02: the response interleaves messages from
all named topics, and **every message carries its own `topic` field**, so one
socket demultiplexes cleanly. This matters beyond tidiness — ntfy.sh rate-limits
concurrent connections per IP, so a per-topic design would break at a dozen
subscriptions.

### Event types

`open` (stream established), `message`, `keepalive` (roughly every 45s),
`poll_request`. Unknown `event` values are ignored forward-compatibly.

### `ServerConnection` (actor, one per server)

State machine: `idle → connecting → open → degraded → backoff`.

Three mechanisms keep it alive across real-world conditions:

1. **Keepalive watchdog.** Any received line — message or keepalive — resets a
   90-second timer. Expiry means the connection is dead and triggers a
   reconnect. This is the primary liveness signal: after a laptop sleeps, a
   TCP connection frequently goes silent rather than erroring, so waiting for
   the stream to terminate is not sufficient.
2. **Wake and network triggers.** `NSWorkspace.didWakeNotification` and
   `NWPathMonitor` path-satisfied transitions force an immediate reconnect that
   **bypasses backoff**, instead of waiting out a 60-second timer after the lid
   opens.
3. **Watermark resume.** Reconnect requests
   `since = min(lastMessageTime) − 5s`, taken over **only those subscriptions
   that already have a watermark**. A subscription without one is never in this
   set, because backfill (below) sets its watermark before the shared stream is
   rebuilt. If no subscription on the server has a watermark yet, the stream
   opens without a `since` parameter. The 5-second margin guards clock skew;
   `uniqueKey` absorbs the resulting duplicates.

Backoff is exponential with jitter (1s, 2s, 4s, …) capped at 60 seconds, reset
on the `open` event.

### New subscription backfill

A brand-new topic has no watermark. Folding it into the shared stream would drag
`min()` to zero and replay every topic's entire server cache. Instead: fetch
`?poll=1&since=all` for that topic **alone** in a one-shot request, set its
watermark from the result, then rebuild the shared stream.

### `ConnectionCoordinator`

Owns one `ServerConnection` per server. Subscribes to workspace sleep/wake and
`NWPathMonitor`. Publishes an aggregate status (`allConnected`, `degraded`,
`offline`, `unauthorized`) that drives the menu bar icon.

## 6. Notifications

Delivered through `UNUserNotificationCenter`. Authorization is requested after a
short explanatory onboarding pane, never as a cold prompt on first launch.

**Grouping.** `threadIdentifier = "{serverID}/{topic}"`, so macOS groups
notifications per topic natively.

**Priority mapping.**

| ntfy priority | Interruption level | Sound |
|---|---|---|
| 1 (min), 2 (low) | `.passive` | none |
| 3 (default) | `.active` | default |
| 4 (high) | `.timeSensitive` | default |
| 5 (max/urgent) | `.timeSensitive` | default |

Priority 5 does **not** map to `.critical` by default. Critical alerts require
the `com.apple.developer.usernotifications.critical-alerts` entitlement, which
Apple grants only by application. The app detects the entitlement at runtime and
upgrades priority 5 to `.critical` when present; absent it, priority 5 degrades
to `.timeSensitive`. Nothing in the build blocks on Apple's approval.

**Actions.** ntfy `actions[]` become `UNNotificationAction`s inside a
`UNNotificationCategory` registered lazily, keyed by a hash of the action set.
`view` opens the URL, `copy` writes to the pasteboard, `http` fires the request
and reports success or failure. `broadcast` is Android-only and is omitted
rather than shown as a button that does nothing.

**Attachments.** Image attachments download to a temporary file and attach as a
`UNNotificationAttachment`, giving a real thumbnail in the banner.

**Activation.** Clicking the notification body opens the message's `click` URL
when one is set; otherwise it opens the History window scrolled to that message.

**Suppression.** Per-topic mute, per-topic `minAlertPriority`, and a global
"record only, never alert" toggle.

## 7. User interface

### Menu bar: `NSStatusItem` + `NSPopover`

Deliberately **not** `MenuBarExtra`. As of macOS 26, `MenuBarExtra` still cannot
provide a right-click context menu, custom icon badging, or programmatic
open/close — and this app needs all three, notably so that clicking a
notification can pop the panel. SwiftUI renders the popover *contents*; only the
status item itself is AppKit. This is the single place where the AppKit answer
beats the SwiftUI one, and it is called out here because swapping it later is
expensive.

The icon is an SF Symbol template image that badges on unread count and switches
to a slashed variant when disconnected, making connection state glanceable
without opening anything.

Popover contents: recent messages grouped by topic, a search field, a connection
status row, and buttons for Compose, History, Settings, and Quit.

### History window

An `NSWindow` hosting a three-column `NavigationSplitView`:

- **Sidebar** — "All Messages", then servers containing topics, with unread
  badges and per-server status dots.
- **List** — `.searchable`, filterable by priority, tag, and date range. Context
  actions: mark read, copy, open click URL, delete.
- **Detail** — title, markdown body via `AttributedString(markdown:)`, priority
  pill, tag chips, timestamp, Quick Look attachment preview, and action buttons.

The app runs with `.accessory` activation policy (no Dock icon) and flips to
`.regular` while a window is open.

### Settings

The standard SwiftUI `Settings` scene, tabbed:

- **General** — launch at login (`SMAppService.mainApp`), retention window,
  badge behavior.
- **Servers** — add, edit, remove; credential entry; a test-connection button.
- **Notifications** — default priority threshold, sound, critical alerts status.
- **Advanced** — export history to JSON, clear data, log level.

### Compose sheet

Covers the full publish API: server and topic pickers, title, body with a
markdown toggle and live preview, priority control, tag token field, click URL,
up to three typed action editors, file attachment (drag-and-drop or picker,
uploaded via `PUT /{topic}`), scheduled delivery (`At` / `In`), email and call
forwarding, and icon URL override.

### Native conventions

Standard shortcuts (⌘N compose, ⌘F search, ⌘, settings), full keyboard
navigation, VoiceOver labels on status indicators, `.formStyle(.grouped)`,
system fonts, and correct Dark Mode and Increase Contrast behavior.

## 8. Retention

Configurable: keep N days (default 30) **and** at most M messages per topic
(default 10,000), whichever bound is hit first. Pruning runs at launch and daily
thereafter. Pruned messages take their attachment files with them.

## 9. Security and open-source hygiene

The repository is public. The following are load-bearing:

- **No credentials in the source tree, ever.** Server tokens and Basic
  credentials are written to the Keychain keyed by server UUID and are never
  placed in SwiftData, logs, crash reports, or the JSON history export.
- **No personal configuration committed.** No default servers, no default
  topics. A fresh clone opens onboarding with an empty list.
- **No signing material committed.** Signing identity, team ID, and
  notarization credentials come from environment variables; notarization uses a
  `notarytool` Keychain profile, never an inline app-specific password.
  `.gitignore` covers local build configuration.
- **Message bodies are treated as sensitive.** Notification payloads routinely
  carry hostnames, IPs, and internal URLs. Default log level never records
  message bodies; verbose logging is opt-in and documented as such.
- **Topic names are effectively passwords** on public ntfy.sh, where anyone
  knowing a topic can read and publish to it. The README says so plainly, and
  the onboarding flow repeats it when the first topic is added.
- **No telemetry, no analytics, no crash reporting to third parties.**

## 10. Error handling

No silent failures. Every condition below is visible in the UI:

| Condition | Behavior |
|---|---|
| 401 / 403 | Mark server `unauthorized`, **stop retrying**, persistent banner plus one-shot notification. Do not hammer. |
| 429 | Honor `Retry-After`; extend backoff. |
| Malformed JSON line | Log, skip the line, keep the stream alive. |
| Attachment download failure | Keep the message; offer retry. |
| Keychain read failure | Treat as no credential; surface in Settings. |
| Network unreachable | `offline` status in the menu bar icon; resume on path-satisfied. |

## 11. Build and distribution

`swift build -c release`, then a script assembles the `.app` bundle
(Info.plist, `.icns` via `iconutil`), signs it, and optionally notarizes.

Hardened runtime is enabled from day one — required for notarization, free
locally. Entitlements are `com.apple.security.network.client` only. **Not
sandboxed**: the chosen distribution channel does not require it, and it keeps
attachment handling simple.

Two signing modes, selected by environment:

| Mode | `SIGN_IDENTITY` | Notarize |
|---|---|---|
| Local development | `Apple Development: …` | no |
| Release | `Developer ID Application: …` | `notarytool submit` + `stapler staple` |

Local development signing uses a stable identity rather than ad-hoc, so the
signature does not change between builds and macOS does not re-prompt for
notification permission on every rebuild.

**Known gap:** the development machine currently has Apple Development
certificates but no Developer ID Application certificate, which requires a paid
Apple Developer Program membership. The release path is therefore designed but
untested until that certificate exists. The local path works today and is not
blocked.

Xcode 26.6 is reached via `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`;
no `sudo xcode-select` is required.

CI (GitHub Actions, macOS runner) builds and runs the test suite unsigned. No
signing secrets are present in CI.

## 12. Testing

Test-driven, with `NtfyKit` as the target surface. Swift Testing (`@Test`).

Unit tests:

- ndjson line decoding, including malformed lines and unknown event types
- keepalive watchdog fires at the correct boundary
- backoff schedule stays within jitter bounds and resets on `open`
- `since=` watermark computation across a topic group, including the
  new-subscription case that must **not** collapse to zero
- deduplication by `uniqueKey` across overlapping replay windows
- priority to interruption-level mapping, including the critical-alerts
  entitlement fallback
- action encode/decode round-trip for all four action types
- retention pruning boundaries, and attachment file cleanup

`MockNtfyServer` — a loopback HTTP server built on Network.framework that
streams canned ndjson with configurable keepalive cadence and scripted
mid-stream disconnects. This lets the connection and reconnect logic be tested
against a real socket rather than a mocked client.

GUI-side behavior that cannot be unit tested — notification delivery, grouping,
sleep/wake recovery — gets a written manual verification checklist in
`docs/manual-tests.md`.

## 13. Build order

The work sequences into five stages, each independently verifiable. The
implementation plan expands these.

1. **Skeleton** — SwiftPM package, `.app` assembly script, local signing,
   launches as an `LSUIElement` app with a status item. Verifies the build path
   end to end before any feature exists.
2. **`NtfyKit` core** — models, REST client, ndjson decoding, `MockNtfyServer`,
   and the connection state machine with its full test suite. No UI. This is the
   bulk of the risk and it is all testable headlessly.
3. **Ingest and persistence** — SwiftData store, dedupe, watermarks, backfill,
   retention pruning.
4. **Surfaces** — notification presentation, menu bar popover, History window,
   Settings.
5. **Publish and release** — compose sheet, attachment upload, then Developer ID
   signing and notarization.

Stage 2 gates everything after it; stages 4 and 5 are largely independent of
each other.

## 14. Spec review items

1. Product name (`Ntfy Bar`), bundle identifier, and license.
2. Whether priority 5 should pursue the critical-alerts entitlement at all.
3. Retention defaults (30 days / 10,000 messages per topic).
