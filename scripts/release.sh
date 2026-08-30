#!/usr/bin/env bash
# Build a release archive for GitHub Releases.
#
#   ./scripts/release.sh
#
# Produces dist/MacFanSpeed-<version>.zip and its SHA-256. Checks the archive
# actually contains a working app before handing it over: a release that is
# missing the embedded helper looks fine until someone tries to enable fan
# control on a machine that has never seen this repository.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)"
APP="build/MacFanSpeed.app"
DIST="dist"
ARCHIVE="$DIST/MacFanSpeed-$VERSION.zip"

fail() { printf '\033[31mFAIL: %s\033[0m\n' "$1" >&2; exit 1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

step "Version $VERSION"

# The icon is committed, so only regenerate it when asked or when it is missing.
# Rendering needs AppKit, which is unreliable on a headless CI runner, and there
# is no reason to redraw an unchanged icon on every release.
if [ "${1:-}" = "--regenerate-icon" ] || [ ! -f Resources/AppIcon.icns ]; then
    step "Regenerating the app icon"
    swift scripts/make-icon.swift
else
    step "Using the committed app icon"
    echo "    pass --regenerate-icon to redraw it"
fi

# A CLI or daemon reporting a different version from the app it shipped with is
# the kind of thing nobody notices until a bug report is impossible to place.
SOURCE_VERSION="$(grep -o 'version = "[^"]*"' Sources/SMCKit/SMCKit.swift | head -1 | cut -d'"' -f2)"
[ "$SOURCE_VERSION" = "$VERSION" ] || fail \
    "SMCKit.version is $SOURCE_VERSION but Info.plist says $VERSION"
echo "    source and bundle versions agree"

step "Clean build"
rm -rf .build build
./scripts/build.sh release

step "Running tests"
swift test 2>&1 | tail -3

# ------------------------------------------------------------------ checks
step "Checking the bundle"

for required in \
    "Contents/MacOS/MacFanSpeed" \
    "Contents/Info.plist" \
    "Contents/Resources/AppIcon.icns" \
    "Contents/Resources/MacFanSpeedHelper" \
    "Contents/Resources/io.github.bradr23.MacFanSpeed.helper.plist" \
    "Contents/Resources/install-helper.sh" \
    "Contents/Resources/uninstall-helper.sh" \
    "Contents/Resources/fanctl"
do
    [ -e "$APP/$required" ] || fail "bundle is missing $required"
done
echo "    all required files present"

# The Swift runtime ships with macOS 14, so nothing should need bundling — but a
# stray dependency would only surface on someone else's Mac.
if otool -L "$APP/Contents/MacOS/MacFanSpeed" | grep -qE "@rpath|/Users/"; then
    otool -L "$APP/Contents/MacOS/MacFanSpeed" | grep -E "@rpath|/Users/" >&2
    fail "the binary links something outside the system"
fi
echo "    links only system frameworks"

MINOS="$(vtool -show-build "$APP/Contents/MacOS/MacFanSpeed" | awk '/minos/ {print $2}')"
[ "$MINOS" = "14.0" ] || fail "deployment target is $MINOS, expected 14.0"
echo "    deployment target $MINOS"

lipo -info "$APP/Contents/MacOS/MacFanSpeed" | grep -q arm64 \
    || fail "binary is not arm64"
echo "    architecture arm64"

codesign --verify --deep --strict "$APP" 2>/dev/null \
    && echo "    signature valid (ad-hoc)" \
    || fail "signature does not verify"

# ------------------------------------------------------------------ archive
step "Packaging"
rm -rf "$DIST"
mkdir -p "$DIST"
# ditto rather than zip: it preserves the bundle structure and extended
# attributes that make the .app open correctly after download.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"

SIZE="$(du -h "$ARCHIVE" | cut -f1)"
SHA="$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)"
echo "$SHA  MacFanSpeed-$VERSION.zip" > "$ARCHIVE.sha256"

step "Done"
echo "  $ARCHIVE  ($SIZE)"
echo "  SHA-256: $SHA"
echo ""
echo "Release notes should mention:"
echo "  - Apple Silicon only, macOS 14+"
echo "  - the app is ad-hoc signed, so first launch needs right-click → Open"
echo "  - fan control needs the helper, installed from Settings › Fan Control"
