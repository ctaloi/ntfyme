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
# the app that links it (--deep covers Sparkle's nested XPC services).
SPARKLE_XCFW="$(find "$ROOT/.build" -type d -name "Sparkle.xcframework" -not -path "*/checkouts/*" 2>/dev/null | head -1 || true)"
if [ -n "$SPARKLE_XCFW" ]; then
    echo "==> embedding Sparkle.framework"
    mkdir -p "$APP/Contents/Frameworks"
    FRAMEWORK_SLICE="$(find "$SPARKLE_XCFW" -maxdepth 2 -type d -name "macos-*" | head -1)"
    cp -R "$FRAMEWORK_SLICE/Sparkle.framework" "$APP/Contents/Frameworks/"
    codesign --force --deep --options runtime "$TIMESTAMP_FLAG" \
        --sign "$SIGN_IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework"
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
