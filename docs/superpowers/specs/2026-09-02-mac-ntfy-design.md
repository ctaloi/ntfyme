# NtfyMe — a native macOS client for ntfy

**Status:** design approved, spec reviewed, ready for implementation planning
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
| Product name | NtfyMe | Settled |
| Bundle identifier | `dev.aloi.NtfyMe` | Settled — see below |
| SwiftPM product / executable | `NtfyMe` | |
| License | MIT | Settled |

The bundle identifier derives from `aloi.dev`, a domain the author controls.
That is the entire point of a reverse-DNS identifier, and it is why the common
`com.github.<user>` form is wrong for anything not published by GitHub itself.

The bundle identifier is **not a free knob**. macOS keys both notification
authorization and Keychain ACLs to the signed bundle identifier, so changing it
silently revokes granted notification permission and makes stored server
credentials unreadable. It is therefore a single named constant in the package
manifest rather than an environment variable, and the README states the
consequence for anyone forking: change it before your first build, or not at
all.

## 3. Architecture

Three SwiftPM targets:

- **`NtfyKit`** (library) — models, REST client, streaming client, connection
  state machine, Keychain access, retention. No AppKit, no SwiftUI. This is
  where the interesting logic lives and where the tests point.
- **`NtfyMe`** (executable) — menu bar, windows, notification presentation.
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
deduplicate rather than duplicate. Measured against this project's toolchain
(Plan 2 Task 4): `@Attribute(.unique)` alone already prevents a duplicate-key
insert from producing a second row — the row count never exceeds one — but
its raw behavior is last-write-wins, letting the replayed row's values
overwrite the stored one. That is wrong here: `Message.isRead` is local
state the server knows nothing about, and reconnect deliberately re-requests
an overlapping window, so an unconditional upsert would silently reset
`isRead` to `false` on every reconnect, undoing what the user had already
read. The store actor therefore queries existing keys for a batch before
inserting and **skips** rather than upserts on a hit (first-write-wins) —
not as a backstop against duplicate rows, which the constraint already
prevents on its own, but as the mechanism that protects locally-owned fields
from server replay. The same protection extends to any future local-only
field on `Message`. This was measured against a single long-lived
`ModelContext` on an in-memory store, not the on-disk SQLite store or
inserts split across separate `ModelContext` instances — see the plan's
"Measured SwiftData behavior" table for that boundary.

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

There is **no race** between the backfill completing and the stream rebuilding.
`since` is a lower bound, not a window: the rebuilt stream requests
`since = min(watermark) − 5s`, and the server replays everything from that point
to now, however long the rebuild took. Messages published during the gap are
delivered on reconnect.

### `since` semantics, as measured

Verified against ntfy.sh on 2026-09-02 (see §5.1 below for why this matters):

| `since` value | Behavior |
|---|---|
| Unix timestamp | Lower bound. Returns everything from that time to now. |
| Message ID (12-char base62) | Exclusive lower bound. **Resolves across a multi-topic subscription** — an ID belonging to topic A correctly positions a stream over `A,B`. |
| Message ID, well-formed but unknown or evicted | **HTTP 200 and a full cache replay.** No error. |
| Malformed value (wrong shape) | HTTP 400, `{"code":40008,"error":"invalid since parameter"}`. |
| Duration (`48h`) or `all` | Lower bound, clamped to the server's cache window. |

### 5.1 Why resume uses a timestamp, not a message ID

Both forms work, and message IDs are more precise — they avoid re-fetching the
overlap. Timestamps are used anyway, for one reason: **their failure mode is
observable and theirs is not.**

A watermark older than the server's cache window is the normal case after a long
offline period. With a message ID, the server cannot resolve it and silently
returns the entire cache with HTTP 200 — a response indistinguishable from a
correct one. With a timestamp, an out-of-window value produces the same full
replay, but the client already knows the watermark predates the window and can
say so. Deduplication by `uniqueKey` makes either correct; only the timestamp
lets the app tell the difference between "resumed cleanly" and "replayed
everything," which §10 requires it to surface — delivered as
`ConnectionDiagnostic.historyGap(since:)` on `ServerConnection.diagnostics`,
since the state enum's `.degraded(.historyGap)` is overwritten by `.open`
within milliseconds and no consumer polling state can observe it there.

Timestamps also carry no clock-skew risk, because the values come from the
server's own `time` field rather than the local clock. The 5-second margin
guards only the boundary case of a message whose timestamp equals the watermark.

`lastMessageID` is still recorded on `Subscription` for diagnostics and log
correlation; it is not used to construct `since`.

### 5.2 The resume point is "caught up to", not "last message"

**Decided 2026-09-02, implemented 2026-09-02** in `WatermarkResolver.resolve`
and `ServerConnection.caughtUpTo` (commit "feat: resume from 'caught up to',
not the oldest message watermark", persistence plan Task 3).

Resuming from `min(lastMessageTime)` across topics is wrong for a quiet topic.
A topic that merely received no messages for longer than the server's cache
window drags the shared `since` outside that window on *every* reconnect — every
lid-open — producing a full-cache replay of every topic and a `hasHistoryGap`
that is false: nothing was missed, the topic was simply quiet.

The connection receives a better signal, but **only the `keepalive` line carries
it**. An earlier revision of this section said "every `open` and `keepalive`
line", and that was wrong in a way that silently lost history.

ntfy sends the `open` line *before* it replays cached messages — its subscribe
handler calls `sub(v, NewOpenMessage(...))` and only then `sendOldMessages(...)`
— and `open` carries `time = now`. So `open`'s timestamp does not prove delivery;
it proves the replay has not started. Treating it as a delivery proof meant that
a socket drop mid-replay advanced the resume point past every message the replay
had not yet sent, and nothing ever asked for them again.

Demonstrated 2026-09-02 in the Stage 3 whole-branch review: scripting
`open(t=1788352812)`, then `message(t=1788335966)`, then a drop, produced a
reconnect asking `since=1788352807` rather than `1788335961` — about 4.7 hours
of history skipped, with `hasHistoryGap` reporting `false`.

Keepalives are emitted only after `sendOldMessages` returns, which is exactly
what makes them the line that proves delivery. So `caughtUpTo` advances on
`keepalive`, and the correct resume point is:

    since = max(min(topic watermarks), caughtUpTo) − margin

This makes `hasHistoryGap` true only after a genuinely long disconnect.

**Resume state must advance on persisted, not received.** `caughtUpTo` is only
safe to persist for a batch that has actually been written to the store: if a
write fails and the resume point has already moved past it, the messages are
permanently absent from the archive and no reconnect will ask for them again.

The persisted `Subscription` model must therefore store a per-server "caught up
to" time alongside the per-topic message watermarks. Deciding this now is what
keeps the persistence schema from freezing the wrong shape.

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

`.timeSensitive` requires the
`com.apple.developer.usernotifications.time-sensitive` entitlement on macOS.
Unlike critical alerts, this one is self-enabled — no Apple approval — but
without it priorities 4 and 5 silently degrade to `.active`. It is listed in
§11's entitlements.

**Critical alerts are deliberately not supported.** Priority 5 maps to
`.timeSensitive`, not `.critical`. Critical alerts require the
`com.apple.developer.usernotifications.critical-alerts` entitlement, which Apple
grants only by individual application, and supporting them would mean carrying a
runtime-detection branch and a second notification path for a capability the app
may never be granted. `.timeSensitive` already breaks through Focus when the
user allows it per-app, which covers the actual need. Decided 2026-09-02.

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
- **Notifications** — default priority threshold, sound, and a shortcut to
  System Settings for the app's notification permission.
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
| Watermark older than the server cache window | Detectable client-side before the request. Log it, deliver `.historyGap(since:)` on `ServerConnection.diagnostics` — a one-shot latched diagnostic, not the transient `.degraded(.historyGap)` state the next line overwrites — and reconnect anyway. A silent full-cache replay must never be mistaken for a clean resume. |
| HTTP 400 `40008` invalid since | A client bug, not a server condition. Log loudly, fall back to `since=all`, and do not retry the malformed value. |

## 11. Build and distribution

`swift build -c release`, then a script assembles the `.app` bundle
(Info.plist, `.icns` via `iconutil`), signs it, and optionally notarizes.

Hardened runtime is enabled from day one — required for notarization, free
locally. **Not sandboxed**: the chosen distribution channel does not require it,
and it keeps attachment handling simple.

Entitlements:

| Entitlement | Why |
|---|---|
| `com.apple.security.network.client` | Outbound connections to ntfy servers |
| `com.apple.developer.usernotifications.time-sensitive` | Priorities 4–5. **Measured 2026-09-02: cannot be used with local Apple Development signing.** `codesign` embeds it successfully, but the app is killed at launch — AMFI reports "no eligible provisioning profiles found" and launchd reports spawn failure. It needs an App ID with the capability enabled and an embedded provisioning profile, so it ships only in the Developer ID release build. Local development builds omit it, which means priorities 4–5 degrade to `.active` during development. |

Critical alerts are not requested; see §6.

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

**Confirmed 2026-09-02, on `macos-26`:** an unsigned binary on a hosted macOS
runner can bind and connect to loopback for `MockNtfyServer` without a
signature or entitlement. `.github/workflows/ci.yml` runs `swift build -v`
and `swift test -v`, unsigned, no `codesign` step, no signing secrets in the
repository.

The first real run, on `macos-15`, never reached the loopback question at
all: it failed in 15 seconds with `package 'ntfyme' is using Swift tools
version 6.2.0 but the installed version is 6.1.0` — `macos-15` ships Swift
6.1, which cannot even parse this package's `swift-tools-version: 6.2` or
its `.macOS(.v26)` platform floor. The workflow was switched to `macos-26`
(the run's toolchain: Xcode 26.6, Apple Swift 6.3.3, `MacOSX26.5.sdk`),
re-pushed, and that run
([`33649713749`](https://github.com/ctaloi/ntfyme/actions/runs/33649713749),
`feat/foundation` at `87053b2`) went green: 66/66 tests, including every
loopback-socket test in `MockNtfyServer` and `ServerConnectionTests`
(`reachesOpenStateAndEmitsMessages`, `stopIsFinalEvenWithEventsInFlight`,
`reconnectNowBypassesTheBackoffDelay`, and the rest) — no binding or
permission error, no ad-hoc signing needed. This matches what was already
observed locally on macOS 26.6.2 against an unsigned SwiftPM test binary.
The ad-hoc-signing fallback (`codesign -s - --force` on the test bundle
before `swift test`) remains available in principle but was not needed and
is not part of the workflow.

## 12. Testing

Test-driven, with `NtfyKit` as the target surface. Swift Testing (`@Test`).

Unit tests:

- ndjson line decoding, including malformed lines and unknown event types
- keepalive watchdog fires at the correct boundary
- backoff schedule stays within jitter bounds and resets on `open`
- `since=` watermark computation across a topic group, including the
  new-subscription case that must **not** collapse to zero
- backfill-to-stream handoff: a message published between the backfill poll and
  the stream rebuild is still delivered, including when the rebuild is delayed
  well past the 5-second margin (`since` is a lower bound, so this must hold)
- a watermark older than the mock server's cache window is detected and reported
  as a history gap rather than being silently treated as a clean resume
- deduplication by `uniqueKey` across overlapping replay windows
- priority to interruption-level mapping across all five levels
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

## 14. Decisions log

All spec review items are closed.

| Decision | Outcome | Date |
|---|---|---|
| Product name | NtfyMe | 2026-09-02 |
| Bundle identifier | `dev.aloi.NtfyMe`, from the author's `aloi.dev` | 2026-09-02 |
| License | MIT | 2026-09-02 |
| Critical alerts | Not supported; priority 5 uses `.timeSensitive` | 2026-09-02 |
| Retention defaults | 30 days / 10,000 messages per topic, both configurable | 2026-09-02 |
