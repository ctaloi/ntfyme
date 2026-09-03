# NtfyMe

A native macOS menu-bar client for [ntfy](https://ntfy.sh). It watches your
subscriptions, delivers native notifications, and keeps a searchable local
archive of every message it has seen.

This project is under active development. Publishing messages, attachment
handling, and notarized distribution are not built yet; everything below is.
Attachment metadata arrives and is modelled, but files are not yet downloaded,
so the History window's Quick Look preview is inert for now.

## What works

- **Multiple servers and topics**, with bearer-token or username/password
  authentication. Credentials live in the Keychain, keyed by a server UUID so
  not even the server's hostname is written alongside them.
- **A menu-bar popover** listing recent messages grouped by topic and server,
  with an unread badge, search, and a connection-status row.
- **A History window** — a three-column browser with a per-server/per-topic
  sidebar showing live connection state, a message list, and a detail pane
  that renders markdown bodies, tags, and the message's own action buttons.
- **Native notifications** with ntfy's priority levels mapped to macOS
  interruption levels, per-topic mute and priority thresholds, a global
  "record only, never alert" switch, and working action buttons. Clicking a
  notification opens its `click` URL, or the History window.
- **A local archive** of every message seen, pruned on a rolling window by
  both age and per-topic count.
- **Resumable streaming**: reconnect with backoff, a keepalive watchdog, and
  per-topic watermarks so a reconnect replays what was missed without
  re-notifying about messages already stored.

Every URL that arrives in a message — a `click` target, an action, a markdown
link — is passed through a single scheme allow-list before it can be opened.
Message content is treated as untrusted input throughout.

## Security: topics and credentials

**On the public ntfy.sh server, a topic name is effectively a password.**
Anyone who knows a topic name can both read from it and publish to it — there
is no separate secret. Treat topic names with the same care as a password,
and prefer a self-hosted server with authentication for anything sensitive.

NtfyMe stores server credentials (URLs, usernames, passwords, access tokens)
in the macOS Keychain. They are never written to the repository, to source
control, or to the app's local database.

## Building

Requires Xcode with the macOS 26 SDK.

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test
Scripts/build-app.sh
open build/NtfyMe.app
```

`Scripts/build-app.sh` builds a release binary with `swift build`, hand-assembles
`build/NtfyMe.app` (`Info.plist` generated from `Scripts/Info.plist.in`), and
code-signs it with `Scripts/NtfyMe.entitlements` using the identity named by
`SIGN_IDENTITY` in `Scripts/config.sh` (default `Apple Development`, resolved
by prefix). If your keychain has more than one identity sharing that name —
including two certs with the identical full common name, which can happen
after a renewal — `codesign` fails with "ambiguous, matches ... and ...".
Run `security find-identity -v -p codesigning` and set `SIGN_IDENTITY` to the
specific SHA-1 hash of the identity to use, via `Scripts/local.sh` (gitignored,
never committed) or the environment.

Set `NOTARIZE=1` and `NOTARY_PROFILE=<profile>` to notarize after signing;
this requires a Developer ID Application certificate and a paid Apple
Developer Program membership, and has not been exercised on this machine.

### Entitlements

`Scripts/NtfyMe.entitlements` grants outbound network access
(`com.apple.security.network.client`) only. The time-sensitive notification
entitlement (`com.apple.developer.usernotifications.time-sensitive`) was
evaluated and left out: `codesign` itself accepted it without complaint, but
the app was then killed on launch. `amfid` and the kernel's AMFI check
rejected the binary — `taskgated-helper: Disallowing dev.aloi.NtfyMe because
no eligible provisioning profiles found`, then `amfid: ... Error
Domain=AppleMobileFileIntegrityError Code=-413 "No matching profile found"`
— and `launchd` reported `Launchd job spawn failed`. `com.apple.developer.*`
capability entitlements require an embedded provisioning profile issued for
an App ID with that capability enabled, which plain local "Apple Development"
signing does not provide. This is expected, is not a blocker for early
development, and is deferred to a future release-signing task once a paid
Developer Program account and Developer ID are available.

## Development

[![CI](https://github.com/ctaloi/ntfyme/actions/workflows/ci.yml/badge.svg)](https://github.com/ctaloi/ntfyme/actions/workflows/ci.yml)

`swift test` runs both suites: `NtfyKit`, including socket-level tests
against a loopback `MockNtfyServer`, and `NtfyMe`, which covers the app
layer's logic and renders each UI surface to a PNG offscreen (see
`Tests/NtfyMeTests/SnapshotSupport.swift` for why `ImageRenderer` is not
used for this):

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test
```

`.github/workflows/ci.yml` builds and tests the package unsigned on a hosted
`macos-26` runner on every push to `main` and every pull request, with no
signing secrets configured. See spec §11 for what CI has established about
loopback networking on an unsigned binary.
