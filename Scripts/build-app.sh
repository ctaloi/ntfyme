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

# `--timestamp` contacts Apple's timestamp authority, so it needs the network
# and an offline build fails at signing rather than producing a runnable app.
# A trusted timestamp is only load-bearing for distribution, so it is required
# on the notarizing path and skipped on the local dev path.
if [ "$NOTARIZE" = "1" ]; then
    TIMESTAMP_FLAG="--timestamp"
else
    TIMESTAMP_FLAG="--timestamp=none"
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
