#!/usr/bin/env bash
# Shared build configuration. Sourced by build-app.sh.
#
# PRODUCT_BUNDLE_ID is effectively permanent: macOS keys notification
# authorization and Keychain ACLs to it. Changing it after a build has been
# installed revokes notification permission and orphans stored credentials.
# Forks should change it before their first build, or not at all.
PRODUCT_NAME="NtfyMe"
PRODUCT_BUNDLE_ID="dev.aloi.NtfyMe"
MARKETING_VERSION="0.1.1"
BUILD_VERSION=3
MINIMUM_MACOS="26.0"

# Override in Scripts/local.sh (gitignored) or the environment.
#
# "Apple Development" below is a friendly placeholder, not guaranteed to
# resolve: `codesign --sign` needs an *unambiguous* match, and a keychain
# with more than one identity sharing a name (even the full common name,
# e.g. two "Apple Development: <Name> (<TeamID>)" certs from renewal) will
# make codesign fail with "ambiguous, matches ... and ...". If that happens,
# run `security find-identity -v -p codesigning` and set SIGN_IDENTITY to
# the specific SHA-1 hash of the identity to use, via Scripts/local.sh or
# the environment — never commit a hash tied to a personal certificate here.
SIGN_IDENTITY="${SIGN_IDENTITY:-Apple Development}"
NOTARIZE="${NOTARIZE:-0}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

# Auto-update (Sparkle) configuration. The feed is the appcast XML the
# release script publishes (default: the repository's own raw URL); the
# EdDSA public key is the *public half* generated once by Sparkle's
# `generate_keys` (the private half lives in the macOS Keychain and must
# never leave it). When the key is empty the app simply never starts its
# updater — dev builds that will never check for updates. Overridable via
# Scripts/local.sh or the environment.
UPDATE_FEED_URL="${UPDATE_FEED_URL:-https://raw.githubusercontent.com/ctaloi/ntfyme/main/appcast.xml}"
SPARKLE_ED_PUBLIC_KEY="${SPARKLE_ED_PUBLIC_KEY:-}"
# Where release artifacts publish (GitHub Releases) and the appcast lives.
GITHUB_REPO="${GITHUB_REPO:-ctaloi/ntfyme}"

# `if` (not `[ -f x ] && . x`) so the absence of local.sh — the normal
# case, since it's gitignored — doesn't trip `set -e` in the sourcing
# script: a failing left side of a top-level `&&` list still exits the
# script under `set -euo pipefail` when this file is sourced with `.`.
if [ -f "$(dirname "${BASH_SOURCE[0]}")/local.sh" ]; then
    . "$(dirname "${BASH_SOURCE[0]}")/local.sh"
fi
