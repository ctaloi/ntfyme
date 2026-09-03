#!/usr/bin/env bash
# Builds a release, signs it for Sparkle, and (re)generates appcast.xml.
#
# One-time setup:
#   1. Build Sparkle's CLI tools (SPM resolves the framework, Xcode builds
#      the CLIs):
#          export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
#          cd .build/checkouts/Sparkle
#          xcodebuild -project Sparkle.xcodeproj -scheme generate_keys -configuration Release -derivedDataPath /tmp/sparkle-tools build
#          xcodebuild -project Sparkle.xcodeproj -scheme sign_update  -configuration Release -derivedDataPath /tmp/sparkle-tools build
#          cp /tmp/sparkle-tools/Build/Products/Release/sign_update .build/checkouts/Sparkle/bin/
#   2. Run `generate_keys` once. It stores the EdDSA keypair in your macOS
#      Keychain. The PUBLIC key belongs in Scripts/config.sh (safe to
#      commit); the private half never leaves the Keychain.
#
# Every release:
#   Scripts/release.sh 0.2.0
# then follow the printed steps: create the GitHub release, upload the zip,
# commit appcast.xml + Scripts/config.sh, push. Sparkle clients see the
# update within their next 24h check (or via Check for Updates).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
. "$HERE/config.sh"

VERSION="${1:?usage: release.sh VERSION   (e.g. 0.2.0)}"
case "$VERSION" in v*) VERSION="${VERSION#v}";; esac

[ -n "$SPARKLE_ED_PUBLIC_KEY" ] || {
    echo "error: SPARKLE_ED_PUBLIC_KEY is empty. Run one-time setup (see the top of this file)." >&2
    exit 1
}

SIGN_UPDATE="$ROOT/.build/checkouts/Sparkle/bin/sign_update"
if [ ! -x "$SIGN_UPDATE" ]; then
    echo "==> sign_update missing; building Sparkle CLI tools"
    export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
    SPARKLE_CHECKOUT="$ROOT/.build/checkouts/Sparkle"
    xcodebuild -project "$SPARKLE_CHECKOUT/Sparkle.xcodeproj" \
        -scheme sign_update -configuration Release \
        -derivedDataPath /tmp/sparkle-tools build >/dev/null
    mkdir -p "$SPARKLE_CHECKOUT/bin"
    cp /tmp/sparkle-tools/Build/Products/Release/sign_update "$SIGN_UPDATE"
fi

echo "==> bumping version to $VERSION in Scripts/config.sh"
sed -i '' \
    -e "s|^MARKETING_VERSION=.*|MARKETING_VERSION=\"$VERSION\"|" \
    -e "s|^BUILD_VERSION=.*|BUILD_VERSION=$((BUILD_VERSION + 1))|" \
    "$HERE/config.sh"
. "$HERE/config.sh"   # reload the bumped values

echo "==> building"
# `build-app.sh` assembles into $APP; source it in a subshell that exports
# the variable? It doesn't export, so recompute the same path here. (Keep
# in sync with build-app.sh's definition.)
APP="$ROOT/build/$PRODUCT_NAME.app"
"$HERE/build-app.sh"

ZIP_NAME="$PRODUCT_NAME-$VERSION.zip"
ZIP="$ROOT/build/$ZIP_NAME"
DOWNLOAD_URL="https://github.com/$GITHUB_REPO/releases/download/v$VERSION/$ZIP_NAME"

echo "==> zipping"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> signing update for Sparkle"
# Prints: sparkle:edSignature="<base64>" length="<bytes>"
SIGN_OUTPUT="$("$SIGN_UPDATE" "$ZIP")"
echo "    $SIGN_OUTPUT"
ED_SIGNATURE="$(sed -E 's/.*edSignature="([^"]+)".*/\1/' <<< "$SIGN_OUTPUT")"
LENGTH="$(sed -E 's/.*length="([^"]+)".*/\1/' <<< "$SIGN_OUTPUT")"

echo "==> updating appcast.xml"
RFC_DATE="$(LC_ALL=en_US.UTF-8 date -u '+%a, %d %b %Y %H:%M:%S %z')"
python3 - "$ROOT/appcast.xml" "$VERSION" "$BUILD_VERSION" "$DOWNLOAD_URL" \
          "$ED_SIGNATURE" "$LENGTH" "$RFC_DATE" "$MINIMUM_MACOS" "$PRODUCT_NAME" <<'PYEOF'
import sys, xml.etree.ElementTree as ET

path, version, build, url, sig, length, date, min_macos, product = sys.argv[1:]

ET.register_namespace("sparkle", "http://www.andymatuschak.org/xml-namespaces/sparkle")
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}

try:
    tree = ET.parse(path)
    channel = tree.getroot().find("channel")
except FileNotFoundError:
    rss = ET.Element("rss", {
        "xmlns:sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle",
        "xmlns:dc": "http://purl.org/dc/elements/1.1/",
        "version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = product
    ET.SubElement(channel, "link").text = f"https://github.com/ctaloi/ntfyme"
    ET.SubElement(channel, "description").text = "Auto-update feed."
    ET.SubElement(channel, "language").text = "en"
    tree = ET.ElementTree(rss)

# Replace any existing item for this version; otherwise append newest-first.
for item in channel.findall("item"):
    v = item.find("sparkle:version", ns)
    if v is not None and v.text == build:
        channel.remove(item)

item = ET.Element("item")
ET.SubElement(item, "title").text = f"Version {version}"
ET.SubElement(item, "pubDate").text = date
ET.SubElement(item, "sparkle:version", ns).text = build
ET.SubElement(item, "sparkle:shortVersionString", ns).text = version
ET.SubElement(item, "link").text = url
ET.SubElement(item, "enclosure", {
    "url": url,
    "sparkle:edSignature": sig,
    "length": length,
    "type": "application/octet-stream"})
ET.SubElement(item, "sparkle:minimumSystemVersion", ns).text = min_macos
channel.insert(0, item) if channel.find("item") is not None else channel.append(item)

ET.indent(tree)
tree.write(path, encoding="utf-8", xml_declaration=True)
print(f"    {path} now lists version {version} (build {build}) newest-first")
PYEOF

cat <<EOF

==========================================================================
Release $VERSION is built and the appcast is updated. Remaining steps:

  1. Create the GitHub release:
        gh release create v$VERSION "$ZIP" \\
           --title "$PRODUCT_NAME $VERSION" --generate-notes
  2. Commit and push (clients check within 24h, or via Check for Updates):
        git add appcast.xml Scripts/config.sh
        git commit -m "Release $VERSION" && git push

The update is protected by the EdDSA signature above — anyone without
your Sparkle private key cannot ship a poisoned appcast.
==========================================================================
EOF
