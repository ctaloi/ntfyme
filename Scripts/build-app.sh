#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
. "$HERE/config.sh"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

CONFIG="${CONFIG:-release}"
APP="$ROOT/build/$PRODUCT_NAME.app"

# Fail before the build rather than after a multi-minute notarization round
# trip: the notary service only accepts Developer ID Application signatures,
# and an Apple Development one comes back "Invalid" with no useful hint. The
# lookup goes through the same string codesign will use, so an ambiguous or
# missing identity is caught here too.
if [ "$NOTARIZE" = "1" ]; then
    IDENTITY_LINE="$(security find-identity -v -p codesigning \
        | grep -F "$SIGN_IDENTITY" || true)"
    case "$IDENTITY_LINE" in
        "")
            echo "error: no codesigning identity matches SIGN_IDENTITY=$SIGN_IDENTITY." >&2
            echo "       Run: security find-identity -v -p codesigning" >&2
            exit 1 ;;
        *"Developer ID Application"*) : ;;
        *)
            echo "error: SIGN_IDENTITY=$SIGN_IDENTITY is not a Developer ID Application" >&2
            echo "       identity, so Apple will not notarize it. Matched:" >&2
            echo "$IDENTITY_LINE" >&2
            exit 1 ;;
    esac
    # Two matches still contain the wanted substring and would slip past the
    # case above, only to fail at `codesign` with "ambiguous, matches ...".
    if [ "$(printf '%s\n' "$IDENTITY_LINE" | grep -c .)" != 1 ]; then
        echo "error: SIGN_IDENTITY=$SIGN_IDENTITY matches more than one identity:" >&2
        echo "$IDENTITY_LINE" >&2
        echo "       Set SIGN_IDENTITY to one identity's SHA-1 hash (Scripts/local.sh)." >&2
        exit 1
    fi
fi

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG" --package-path "$ROOT"
BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)/$PRODUCT_NAME"

# `--timestamp` contacts Apple's timestamp authority, so it needs the network
# and an offline build fails at signing rather than producing a runnable app.
# A trusted timestamp is only load-bearing for distribution, so it is required
# on the notarizing path and skipped on the local dev path.
if [ "$NOTARIZE" = "1" ]; then
    TIMESTAMP_FLAG="--timestamp"
else
    TIMESTAMP_FLAG="--timestamp=none"
fi

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$PRODUCT_NAME"

# The app icon. Generated from Scripts/icon/AppIcon-1024.png — see
# Tests/NtfyMeTests/IconRender.swift for how that master is drawn.
cp "$HERE/icon/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

sed -e "s|__PRODUCT_NAME__|$PRODUCT_NAME|g" \
    -e "s|__BUNDLE_ID__|$PRODUCT_BUNDLE_ID|g" \
    -e "s|__MARKETING_VERSION__|$MARKETING_VERSION|g" \
    -e "s|__BUILD_VERSION__|$BUILD_VERSION|g" \
    -e "s|__MINIMUM_MACOS__|$MINIMUM_MACOS|g" \
    -e "s|__UPDATE_FEED_URL__|$UPDATE_FEED_URL|g" \
    -e "s|__SPARKLE_ED_PUBLIC_KEY__|$SPARKLE_ED_PUBLIC_KEY|g" \
    "$HERE/Info.plist.in" > "$APP/Contents/Info.plist"

# Sparkle (auto-update): embed the framework the SPM resolution fetched, so
# the app can actually run its updater. The framework must be signed before
# the app that links it: signing the app seals the resources under it, so a
# framework re-signed afterwards invalidates the outer signature.
SPARKLE_XCFW="$(find "$ROOT/.build" -type d -name "Sparkle.xcframework" -not -path "*/checkouts/*" 2>/dev/null | head -1 || true)"
if [ -n "$SPARKLE_XCFW" ]; then
    echo "==> embedding Sparkle.framework"
    mkdir -p "$APP/Contents/Frameworks"
    FRAMEWORK_SLICE="$(find "$SPARKLE_XCFW" -maxdepth 2 -type d -name "macos-*" | head -1)"
    cp -R "$FRAMEWORK_SLICE/Sparkle.framework" "$APP/Contents/Frameworks/"

    # Sign Sparkle inside-out. Apple documents `--deep` as unsuitable for
    # distribution: it re-signs nested code with the *outer* bundle's flags
    # and entitlements, and its results are not what the notary service
    # checks. Local `codesign --verify --strict` still passes, so the
    # failure surfaces only as a notarization rejection listing each nested
    # binary. Sparkle carries four pieces of nested code — two XPC services,
    # the Updater app, and the Autoupdate tool — each of which must be
    # signed in its own right, deepest first, before the framework that
    # seals them.
    SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
    for nested in \
        "Versions/B/XPCServices/Downloader.xpc" \
        "Versions/B/XPCServices/Installer.xpc" \
        "Versions/B/Updater.app" \
        "Versions/B/Autoupdate"
    do
        [ -e "$SPARKLE_FW/$nested" ] || continue
        codesign --force --options runtime "$TIMESTAMP_FLAG" \
            --sign "$SIGN_IDENTITY" "$SPARKLE_FW/$nested"
    done
    codesign --force --options runtime "$TIMESTAMP_FLAG" \
        --sign "$SIGN_IDENTITY" "$SPARKLE_FW"
    if [ -z "$SPARKLE_ED_PUBLIC_KEY" ]; then
        echo "    (note: SPARKLE_ED_PUBLIC_KEY is empty — this build will not check for updates;" \
             "run .build/checkouts/Sparkle/bin/generate_keys once and set it in Scripts/local.sh)"
    fi
else
    echo "==> Sparkle.xcframework not found in .build (run \`swift build\` once to resolve it)" >&2
    exit 1
fi

echo "==> codesign as: $SIGN_IDENTITY ($TIMESTAMP_FLAG)"
codesign --force --options runtime "$TIMESTAMP_FLAG" \
    --entitlements "$HERE/$PRODUCT_NAME.entitlements" \
    --sign "$SIGN_IDENTITY" "$APP"
# --deep is wrong for *signing* but right for verifying: it walks into
# Sparkle's nested code so a mis-signed XPC service fails here rather than
# at the notary service several minutes later.
codesign --verify --deep --strict --verbose=2 "$APP"

if [ "$NOTARIZE" = "1" ]; then
    [ -n "$NOTARY_PROFILE" ] || { echo "NOTARY_PROFILE required when NOTARIZE=1" >&2; exit 1; }
    echo "==> notarizing"
    ZIP="$ROOT/build/$PRODUCT_NAME.zip"
    # `--noextattr --norsrc` is load-bearing, not tidiness. Copying the framework
    # into the bundle makes macOS stamp com.apple.provenance on every path,
    # symlinks included, and that attribute is kernel-managed — `xattr -c` does
    # not remove it. Plain `ditto -c -k` then encodes those attributes into the
    # archive as AppleDouble "._name" entries. `ditto -x -k` restores them as
    # real attributes, but Archive Utility (what Safari and Finder use) and
    # unzip cannot attach an attribute to a symlink, so they write the sidecars
    # out as ordinary files. In a framework's root directory those are unsealed
    # content, and Gatekeeper rejects the app:
    #     unsealed contents present in the root directory of an embedded framework
    # Excluding the attributes from the archive removes the sidecars at source.
    ditto -c -k --noextattr --norsrc --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    rm -f "$ZIP"
    xcrun stapler staple "$APP"

    # The build is only actually shippable if Gatekeeper says so. spctl runs
    # the same assessment a downloader's first launch runs, so it is the
    # check that corresponds to the dialog users would otherwise see —
    # a stronger statement than "notarytool and stapler both exited 0".
    # If notarization came back Invalid, `stapler staple` above has already
    # failed the script under `set -e`; see `xcrun notarytool log <id>` for
    # the per-file reasons.
    echo "==> verifying Gatekeeper acceptance"
    spctl --assess --type exec --verbose=4 "$APP"
    xcrun stapler validate "$APP"
fi

echo "==> built $APP"
