#!/usr/bin/env bash
# Build all targets and assemble MacFanSpeed.app.
#
# Usage: scripts/build.sh [debug|release]     (default: release)
#
# Output:
#   build/MacFanSpeed.app   — the menu bar app, ad-hoc signed
#   build/fanctl            — debug CLI
#   build/FanHelper         — privileged helper, also embedded in the app bundle
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/MacFanSpeed.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/MacFanSpeed" "$APP/Contents/MacOS/MacFanSpeed"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Embed everything needed to enable fan control on a machine that has only the
# app — no source tree, no build output. The Settings window runs these.
cp "$BIN/FanHelper" "$APP/Contents/Resources/MacFanSpeedHelper"
cp "$BIN/fanctl" "$APP/Contents/Resources/fanctl"
cp Resources/io.github.bradr23.MacFanSpeed.helper.plist "$APP/Contents/Resources/"
cp scripts/install-helper.sh scripts/uninstall-helper.sh "$APP/Contents/Resources/"
chmod +x "$APP/Contents/Resources/install-helper.sh" \
         "$APP/Contents/Resources/uninstall-helper.sh" \
         "$APP/Contents/Resources/MacFanSpeedHelper" \
         "$APP/Contents/Resources/fanctl"

# Copy the standalone tools next to the bundle for convenience.
cp "$BIN/fanctl" build/fanctl
cp "$BIN/FanHelper" build/FanHelper

# Ad-hoc signature. The project ships without a Developer ID; see README
# "Installing" for what this means for users on other Macs.
echo "==> codesign (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

echo "==> built $APP"
