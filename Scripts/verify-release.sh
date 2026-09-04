#!/usr/bin/env bash
# Answers one question: would a stranger's Mac open this download?
#
# Two releases have failed that question for different reasons, and both
# passed the checks in place at the time:
#
#   0.1.1  signed with an Apple Development certificate, which authorizes the
#          app only on the developer's own registered machines.
#   0.1.2  signed and notarized correctly, but archived with plain
#          `ditto -c -k`. That encodes the bundle's extended attributes as
#          AppleDouble "._name" entries; Archive Utility cannot attach an
#          attribute to a symlink, so it writes them out as ordinary files.
#          Nine landed in Sparkle.framework's root, where they are unsealed
#          content, and Gatekeeper refused the app.
#
# The 0.1.2 check failed because it extracted with `ditto -x -k`, which
# round-trips its own output faithfully and therefore cannot observe the bug.
# So the assertions below lead with tool-independent invariants — no
# AppleDouble entries in the archive, no "._" files in the bundle — and treat
# extract-and-assess as confirmation rather than as the definition.
#
# Usage:
#   Scripts/verify-release.sh <archive.zip>      verify a local archive
#   Scripts/verify-release.sh --version 0.1.3    verify what is published,
#                                                plus appcast consistency
#   Scripts/verify-release.sh --archive 0.1.3    published archive only
#   Scripts/verify-release.sh --appcast 0.1.3    appcast consistency only
#   Scripts/verify-release.sh --self-test        prove the verifier still
#                                                detects the 0.1.2 regression
#
# Set VERIFY_LAUNCH=1 to additionally run the app for five seconds and
# require it to stay up. Scripts/release.sh does this; CI does not.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
. "$HERE/config.sh"

FAILURES=0
# What this run actually establishes, so the closing line does not claim
# more than was checked — an appcast run says nothing about a binary.
SUBJECT="this build would open on someone else's Mac"
pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1" >&2; FAILURES=$((FAILURES + 1)); }

# Verify one archive. Collects every failure rather than stopping at the
# first, so one run tells you everything that is wrong with a build.
verify_archive() {
    zip="$1"
    echo "==> $zip"

    if [ ! -f "$zip" ]; then fail "archive does not exist"; return 1; fi

    # Invariant 1: the archive carries no AppleDouble payload. This is the
    # property that matters; which extractor materialises it, and how, is an
    # implementation detail that can change.
    sidecars="$(unzip -l "$zip" 2>/dev/null | grep -cE '/\._|__MACOSX' | tr -d ' ')"
    if [ "$sidecars" = "0" ]; then
        pass "archive contains no AppleDouble entries"
    else
        fail "archive contains $sidecars AppleDouble entries — rebuild with 'ditto -c -k --noextattr --norsrc'"
    fi

    dir="$(mktemp -d)"
    # unzip, not ditto: ditto restores its own sidecars as real extended
    # attributes and so reproduces none of the damage a browser does.
    unzip -q "$zip" -d "$dir" 2>/dev/null
    app="$dir/$PRODUCT_NAME.app"
    if [ ! -d "$app" ]; then fail "archive does not contain $PRODUCT_NAME.app"; rm -rf "$dir"; return 1; fi

    # Invariant 2: nothing anywhere in the bundle is an AppleDouble file.
    stray="$(find "$app" -name '._*' 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$stray" = "0" ]; then
        pass "extracted bundle contains no '._' files"
    else
        fail "extracted bundle contains $stray '._' files, e.g. $(find "$app" -name '._*' | head -1)"
    fi

    # Every @rpath dependency must actually resolve. 0.1.3 passed every
    # check above and still died in dyld: `swift build` links the binary
    # with only an @loader_path rpath, which resolves in .build (SwiftPM
    # stages Sparkle.framework beside the binary) and not in the bundle,
    # where the framework sits in Contents/Frameworks. Signature and
    # archive checks establish that macOS would *permit* the app to launch;
    # they say nothing about whether it can. This resolves the load
    # commands the way dyld does, which needs no window server and so runs
    # anywhere.
    if linkage="$(python3 - "$app" <<'PY'
import os, subprocess, sys

bundle = sys.argv[1]
problems = []

def macho_kind(path):
    try:
        out = subprocess.run(["file", "-b", path], capture_output=True, text=True).stdout
    except Exception:
        return None
    if "Mach-O" not in out:
        return None
    return "executable" if "executable" in out else "library"

def load_commands(path):
    out = subprocess.run(["otool", "-l", path], capture_output=True, text=True).stdout
    rpaths, deps, cmd = [], [], None
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("cmd "):
            cmd = line.split()[1]
        elif line.startswith("path ") and cmd == "LC_RPATH":
            rpaths.append(line.split()[1])
        elif line.startswith("name ") and cmd in ("LC_LOAD_DYLIB", "LC_LOAD_WEAK_DYLIB"):
            deps.append(line.split()[1])
    return rpaths, deps

for root, dirs, files in os.walk(bundle):
    # Versions/Current duplicates Versions/B through a symlink.
    if os.path.islink(root):
        continue
    for name in files:
        path = os.path.join(root, name)
        if os.path.islink(path):
            continue
        kind = macho_kind(path)
        if kind != "executable":
            continue
        rpaths, deps = load_commands(path)
        here = os.path.dirname(path)
        for dep in deps:
            if not dep.startswith("@rpath/"):
                continue
            suffix = dep[len("@rpath/"):]
            tried, found = [], False
            for rp in rpaths:
                # For a main executable both anchors are its own directory.
                base = rp.replace("@executable_path", here).replace("@loader_path", here)
                candidate = os.path.normpath(os.path.join(base, suffix))
                tried.append(candidate)
                if os.path.exists(candidate):
                    found = True
                    break
            if not found:
                rel = os.path.relpath(path, bundle)
                problems.append("%s needs %s; rpaths %s resolve to nothing" %
                                (rel, dep, rpaths or "[]"))

for pr in problems:
    print("    " + pr)
sys.exit(1 if problems else 0)
PY
    )"; then
        pass "every @rpath dependency resolves inside the bundle"
    else
        printf '%s\n' "$linkage"
        fail "unresolved @rpath dependency — the app will die in dyld at launch"
    fi

    # The check that actually caught 0.1.2. --deep is wrong for signing and
    # right for verifying: it walks into Sparkle's nested code.
    if codesign --verify --deep --strict "$app" 2>/dev/null; then
        pass "codesign --verify --deep --strict"
    else
        fail "codesign: $(codesign --verify --deep --strict "$app" 2>&1 | tail -1)"
    fi

    info="$(codesign -dv --verbose=2 "$app" 2>&1)"

    # The 0.1.1 failure mode. An Apple Development signature is not a
    # distribution signature, and Apple will not notarize one.
    case "$info" in
        *"Authority=Developer ID Application"*) pass "signed with a Developer ID Application certificate" ;;
        *) fail "not Developer ID signed: $(printf '%s\n' "$info" | grep -m1 'Authority=' || echo 'unsigned')" ;;
    esac

    # Notarization requires the hardened runtime; without it the ticket
    # cannot be issued, so its absence means the build path regressed.
    case "$info" in
        *"flags=0x10000(runtime)"*) pass "hardened runtime enabled" ;;
        *) fail "hardened runtime missing: $(printf '%s\n' "$info" | grep -m1 'flags=' || echo 'no flags')" ;;
    esac

    # A stapled ticket is what lets the app open on a Mac that cannot reach
    # Apple. Notarized-but-unstapled works online and fails offline.
    if xcrun stapler validate "$app" >/dev/null 2>&1; then
        pass "notarization ticket stapled"
    else
        fail "no stapled notarization ticket"
    fi

    # The assessment a first launch runs. Confirmation of the above rather
    # than a substitute for it.
    assess="$(spctl --assess --type exec --verbose=4 "$app" 2>&1)"
    case "$assess" in
        *"accepted"*"Notarized Developer ID"*|*"Notarized Developer ID"*)
            pass "spctl: accepted, source=Notarized Developer ID" ;;
        *) fail "spctl: $(printf '%s\n' "$assess" | tail -1)" ;;
    esac

    # Opt-in because it runs the real app for a few seconds, and because a
    # CI runner is a poor place to judge whether a GUI app stays up. The
    # static checks above cover this bug specifically; this covers the
    # general case of an app that launches and immediately dies, which is
    # the only thing that actually proves the download works.
    [ "${VERIFY_LAUNCH:-0}" = "1" ] && launch_check "$app"

    rm -rf "$dir"
}

# Run it. Every other check establishes that macOS would permit this app to
# launch; none of them establish that it does. 0.1.3 cleared all of them and
# then died in dyld.
launch_check() {
    app="$1"
    log="$(mktemp)"
    "$app/Contents/MacOS/$PRODUCT_NAME" >/dev/null 2>"$log" &
    pid=$!
    sleep 5
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        pass "launched and stayed up for 5s"
    else
        wait "$pid" 2>/dev/null
        fail "exited immediately after launch: $(sed -n '1,3p' "$log" | tr '\n' ' ')"
    fi
    rm -f "$log"
}

# Every enclosure the feed advertises must actually be downloadable at the
# advertised size. An item pointing at a withdrawn asset is how a feed goes
# stale without anyone noticing.
verify_appcast() {
    feed="$1"; want_version="$2"
    echo "==> appcast $feed"
    xml="$(mktemp)"
    if ! curl -sfL "$feed" -o "$xml" 2>/dev/null; then fail "appcast is not fetchable"; rm -f "$xml"; return 1; fi

    if python3 - "$xml" "$want_version" <<'PY'
import sys, time, urllib.request, xml.etree.ElementTree as ET
S = "http://www.andymatuschak.org/xml-namespaces/sparkle"
path, want = sys.argv[1], sys.argv[2]
items = ET.parse(path).getroot().find("channel").findall("item")
ok, seen = True, []
for it in items:
    v = it.findtext("{%s}shortVersionString" % S)
    seen.append(v)
    enc = it.find("enclosure")
    url, length = enc.get("url"), int(enc.get("length"))
    req = urllib.request.Request(url, method="HEAD")
    # Retry transient failures. A flaky HEAD against a release CDN is not a
    # bad release, and reporting it as one trains people to ignore the check.
    last = None
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                actual = int(r.headers.get("Content-Length", -1))
            if actual != length:
                print("    %s: length says %d, server serves %d" % (v, length, actual)); ok = False
            last = None
            break
        except Exception as e:
            last = e
            time.sleep(2 * (attempt + 1))
    if last is not None:
        print("    %s: enclosure not reachable after 3 attempts (%s)" % (v, last)); ok = False
if want not in seen:
    print("    %s is not listed in the feed (has: %s)" % (want, ", ".join(seen))); ok = False
sys.exit(0 if ok else 1)
PY
    then
        pass "every appcast enclosure resolves at its advertised length, and $want_version is listed"
    else
        fail "appcast is inconsistent with what is published"
    fi
    rm -f "$xml"
}

# Rebuild the 0.1.2 bug on purpose and require the verifier to catch it. A
# guard only ever exercised against good input proves nothing.
self_test() {
    app="$ROOT/build/$PRODUCT_NAME.app"
    [ -d "$app" ] || { echo "self-test needs $app (run Scripts/build-app.sh first)" >&2; exit 1; }
    dir="$(mktemp -d)"
    echo "==> self-test: archiving without --noextattr, which is how 0.1.2 shipped"
    ditto -c -k --keepParent "$app" "$dir/bad.zip"

    before=$FAILURES
    verify_archive "$dir/bad.zip" >/dev/null 2>&1
    if [ "$FAILURES" -gt "$before" ]; then
        FAILURES=$before
        pass "verifier rejects a plain 'ditto -c -k' archive"
    else
        FAILURES=$before
        fail "verifier ACCEPTED a plain 'ditto -c -k' archive — it would not catch the 0.1.2 regression"
    fi
    rm -rf "$dir"
}

case "${1:-}" in
    --self-test)
        SUBJECT="the verifier still detects the 0.1.2 regression"
        self_test ;;
    --version | --archive)
        v="${2:?usage: verify-release.sh --version 0.1.3}"
        dir="$(mktemp -d)"
        url="https://github.com/$GITHUB_REPO/releases/download/v$v/$PRODUCT_NAME-$v.zip"
        echo "==> downloading $url"
        curl -sfL "$url" -o "$dir/$PRODUCT_NAME-$v.zip" || fail "published asset is not downloadable"
        [ "$1" = "--archive" ] && SUBJECT="the published $v archive would open on someone else's Mac"
        verify_archive "$dir/$PRODUCT_NAME-$v.zip"
        # The release is created before appcast.xml is pushed, so a check
        # running off the release event would always find the feed a commit
        # behind. --archive skips it; the push to main checks it instead.
        [ "$1" = "--archive" ] || verify_appcast "$UPDATE_FEED_URL" "$v"
        rm -rf "$dir" ;;
    --appcast)
        SUBJECT="the appcast agrees with what is published"
        verify_appcast "$UPDATE_FEED_URL" "${2:?usage: verify-release.sh --appcast 0.1.3}" ;;
    "" | -h | --help)
        sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)
        verify_archive "$1" ;;
esac

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "PASS — $SUBJECT."
else
    echo "FAIL — $FAILURES check(s) failed; do not ship this." >&2
    exit 1
fi
