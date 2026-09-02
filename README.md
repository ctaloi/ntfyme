# NtfyMe

A native macOS menu-bar client for [ntfy](https://ntfy.sh). It watches your
subscriptions, delivers native notifications, and keeps a searchable local
archive of every message it has seen.

This project is under active development; most features described in
`docs/` do not exist yet. This repository currently proves out the build
path only: a SwiftPM package that produces a launchable, code-signed
`NtfyMe.app`.

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

`swift test` runs the full `NtfyKit` suite, including socket-level tests
against a loopback `MockNtfyServer`:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test
```

`.github/workflows/ci.yml` builds and tests the package unsigned on a hosted
`macos-15` runner on every push to `main` and every pull request, with no
signing secrets configured. This repository has no git remote yet, so that
workflow has never run — there is no build-status badge here because there is
no run to point one at. See spec §11 for what is and isn't established about
loopback networking on an unsigned CI binary.
