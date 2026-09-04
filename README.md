# NtfyMe

A native macOS app for [ntfy](https://ntfy.sh) — it lives in your Dock, its menu bar, and your Notification Center. It watches your
subscriptions, delivers native notifications, and keeps a searchable local
archive of every message it has seen.

This project is under active development.

## What works

- **Multiple servers and topics**, with bearer-token or username/password
  authentication. Credentials live in the Keychain, keyed by a server UUID so
  not even the server's hostname is written alongside them.
- **A menu-bar popover** listing recent messages grouped by topic and server,
  with an unread badge, search, and a connection-status row.
- **A History window** — a three-column browser with a per-server/per-topic
  sidebar showing live connection state, a message list, and a detail pane
  that renders markdown bodies, tags, and the message's own action buttons.
  Attachments are downloaded to disk and offered for Quick Look preview.
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
`build/NtfyMe.app` (`Info.plist` generated from `Scripts/Info.plist.in`), signs
the embedded `Sparkle.framework` inside-out, and code-signs the bundle with
`Scripts/NtfyMe.entitlements` under the hardened runtime, using the identity
named by `SIGN_IDENTITY` in `Scripts/config.sh` (default
`Developer ID Application`, resolved by prefix).

If your keychain has more than one identity sharing that name — two certs with
the identical full common name, which happens after a renewal — `codesign`
fails with "ambiguous, matches ... and ...". Run
`security find-identity -v -p codesigning` and set `SIGN_IDENTITY` to the
specific SHA-1 hash of the identity to use, via `Scripts/local.sh` (gitignored,
never committed) or the environment.

### Signing identity: why it must be Developer ID

An **Apple Development** certificate signs a bundle that runs only on the
developer's own registered machines. Anyone else who downloads it gets

> "NtfyMe" Not Opened — Apple could not verify "NtfyMe" is free of malware
> that may harm your Mac or compromise your privacy.

with no "Open" button; on macOS 15 and later the right-click → Open escape
hatch no longer applies to that dialog. There is no signing trick that avoids
it — ad-hoc signing and re-zipping do not help, because the check is for a
**Developer ID Application** signature plus a notarization ticket. Version
0.1.1 shipped with an Apple Development signature and was affected. 0.1.2 was
signed and notarized correctly but shipped a bad *archive* (see below). Both
downloads are withdrawn; 0.1.3 and later are the first that actually open.

Setup, once per machine:

1. **Developer ID Application certificate** (needs a paid Apple Developer
   Program membership): Xcode → Settings → Accounts → select the team →
   Manage Certificates → **+** → Developer ID Application. Confirm with
   `security find-identity -v -p codesigning`.
2. **Notarization credentials**, stored in the Keychain rather than in this
   repo. Create an app-specific password at appleid.apple.com, then:

   ```bash
   xcrun notarytool store-credentials ntfyme-notary \
       --apple-id <your-apple-id> --team-id 4R4AEU924W
   ```

   `ntfyme-notary` is the default `NOTARY_PROFILE` in `Scripts/config.sh`.

### Archiving: why the zip is built with `--noextattr --norsrc`

A correctly signed and notarized app can still be rejected if the archive is
built carelessly, and 0.1.2 was. Copying `Sparkle.framework` into the bundle
makes macOS stamp `com.apple.provenance` on every path, symlinks included;
the attribute is kernel-managed, so `xattr -c` will not remove it. Plain
`ditto -c -k` encodes those attributes into the zip as AppleDouble `._name`
entries. `ditto -x -k` restores them as real attributes, but Archive Utility
— what Safari and Finder use — cannot attach an attribute to a symlink, so
it writes the sidecars out as ordinary files:

```
Sparkle.framework/._Sparkle  ._Autoupdate  ._Updater.app  ._XPCServices  ...
```

Files in a framework's root directory that the signature does not cover are
unsealed content, and Gatekeeper refuses the app with *"unsealed contents
present in the root directory of an embedded framework"* — the same
user-facing dialog as an unsigned app.

`--noextattr --norsrc` keeps the attributes out of the archive at source.
`Scripts/release.sh` then extracts each archive with `unzip` rather than
`ditto` and re-runs `spctl` on the result: `ditto` round-trips its own
output faithfully and therefore cannot see this class of bug, so verifying
with it proves nothing about what a browser will produce.

`Scripts/verify-release.sh` checks a build the way a stranger's Mac would —
archive hygiene, Developer ID authority, hardened runtime, stapled ticket,
`spctl`, and appcast consistency. `Scripts/release.sh` gates on it and will
not publish a build it rejects; a GitHub workflow re-runs it against the
published artifact. Run it by hand on anything you are unsure about:

```bash
Scripts/verify-release.sh --version 0.1.3      # what is published
Scripts/verify-release.sh ~/Downloads/Foo.zip  # a file you just downloaded
```

Notarization is off for local dev builds — it needs the network and takes
minutes — and `Scripts/release.sh` forces it on, so a published artifact
cannot ship without a ticket. Set `NOTARIZE=1` to exercise it by hand. On
that path `build-app.sh` refuses to start unless `SIGN_IDENTITY` resolves to
a Developer ID Application identity, submits the zipped app to
`xcrun notarytool`, staples the ticket into the bundle, and then asserts
`spctl --assess --type exec` accepts it — the same assessment a downloader's
first launch runs.

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
an App ID with that capability enabled. Developer ID signing does not supply
one either, so moving to Developer ID did not change this; adding the
entitlement would mean provisioning the App ID and embedding the profile.
Notifications work without it — the entitlement only affects whether they can
break through Focus.

## Auto-updates

Releases use [Sparkle](https://sparkle-project.org): the app checks an
appcast (every 24h, or via App menu → Check for Updates, ⌘U) and
self-installs updates signed with our EdDSA key. One-time setup:

```bash
swift build   # resolves Sparkle
# Build Sparkle's CLI tools once (SPM resolves the framework, Xcode builds the CLIs)
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd .build/checkouts/Sparkle
xcodebuild -project Sparkle.xcodeproj -scheme generate_keys -configuration Release -derivedDataPath /tmp/sparkle-tools build
xcodebuild -project Sparkle.xcodeproj -scheme sign_update  -configuration Release -derivedDataPath /tmp/sparkle-tools build
mkdir -p bin
cp /tmp/sparkle-tools/Build/Products/Release/sign_update bin/
/tmp/sparkle-tools/Build/Products/Release/generate_keys          # keypair → macOS Keychain
/tmp/sparkle-tools/Build/Products/Release/generate_keys -p       # prints the public key
# If the public key changes (rotation), copy it into Scripts/config.sh.
```

The private half never leaves your Keychain and never touches the repo.
The **public** key is committed in `Scripts/config.sh` on purpose — it
verifies updates but cannot create them. Builds without the private key in
your Keychain cannot cut a release, but can still run the app.

Cutting a release:

```bash
Scripts/release.sh 0.2.0
```

That bumps the version, builds and signs the app, zips it, signs the zip for
Sparkle, and updates `appcast.xml` (newest-first) in the repository root.
Then create the GitHub release with the printed `gh release create` command,
commit `appcast.xml` + `Scripts/config.sh`, and push — clients see the
update within their next check. The EdDSA signature is what makes the
appcast safe to host anywhere: without your private key, nobody can ship a
poisoned update to your users.

For the complete operator runbook — release, site deploy, GitHub About,
Cloudflare DNS, and what pushes to `main` do — see `docs/release-and-deploy.md`.

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
