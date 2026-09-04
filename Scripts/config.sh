#!/usr/bin/env bash
# Shared build configuration. Sourced by build-app.sh.
#
# PRODUCT_BUNDLE_ID is effectively permanent: macOS keys notification
# authorization and Keychain ACLs to it. Changing it after a build has been
# installed revokes notification permission and orphans stored credentials.
# Forks should change it before their first build, or not at all.
PRODUCT_NAME="NtfyMe"
PRODUCT_BUNDLE_ID="dev.aloi.NtfyMe"
MARKETING_VERSION="0.1.2"
BUILD_VERSION=4
MINIMUM_MACOS="26.0"

# Override in Scripts/local.sh (gitignored) or the environment.
#
# Must be a "Developer ID Application" identity. An "Apple Development"
# certificate signs a bundle that only runs on the developer's own
# registered machines: Gatekeeper rejects it everywhere else with "Apple
# could not verify <app> is free of malware", and notarytool refuses it
# outright. Developer ID is the only identity Apple will notarize for
# distribution outside the App Store.
#
# The value is passed to `codesign --sign`, which needs an *unambiguous*
# match. The prefix below resolves as long as the keychain holds exactly
# one Developer ID Application identity; if `security find-identity -v -p
# codesigning` lists more than one (renewals leave the old one behind),
# codesign fails with "ambiguous, matches ... and ...". Set SIGN_IDENTITY
# to that identity's SHA-1 hash via Scripts/local.sh or the environment —
# never commit a hash tied to a personal certificate here.
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"

# Notarization: Apple's malware scan, whose ticket is what actually silences
# the Gatekeeper dialog. Off for local dev builds (it needs the network and
# takes minutes); Scripts/release.sh turns it on and refuses to publish
# without it. NOTARY_PROFILE names a keychain item created once by
#     xcrun notarytool store-credentials
# (see README "Building"); the credentials never appear in this file.
NOTARIZE="${NOTARIZE:-0}"
NOTARY_PROFILE="${NOTARY_PROFILE:-ntfyme-notary}"

# Auto-update (Sparkle) configuration. The feed is the appcast XML the
# release script publishes (default: the repository's own raw URL); the
# EdDSA public key is the *public half* generated once by Sparkle's
# `generate_keys` (the private half lives in the macOS Keychain and must
# never leave it). When the key is empty the app simply never starts its
# updater — dev builds that will never check for updates. Overridable via
# Scripts/local.sh or the environment.
UPDATE_FEED_URL="${UPDATE_FEED_URL:-https://raw.githubusercontent.com/ctaloi/ntfyme/main/appcast.xml}"
# The EdDSA PUBLIC key — safe (and right) to commit; it verifies update
# signatures but cannot create them. The private half lives only in the
# release machine's Keychain (see README "Auto-updates").
SPARKLE_ED_PUBLIC_KEY="${SPARKLE_ED_PUBLIC_KEY:-XQQcXU8Xxf/us/k4rHx1b3NN8EE/rXScgBaMn+3LoIE=}"
# Where release artifacts publish (GitHub Releases) and the appcast lives.
GITHUB_REPO="${GITHUB_REPO:-ctaloi/ntfyme}"

# `if` (not `[ -f x ] && . x`) so the absence of local.sh — the normal
# case, since it's gitignored — doesn't trip `set -e` in the sourcing
# script: a failing left side of a top-level `&&` list still exits the
# script under `set -euo pipefail` when this file is sourced with `.`.
if [ -f "$(dirname "${BASH_SOURCE[0]}")/local.sh" ]; then
    . "$(dirname "${BASH_SOURCE[0]}")/local.sh"
fi
