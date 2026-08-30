#!/usr/bin/env bash
# Install the privileged fan control daemon.
#
# Runs from two places and must work identically in both:
#   - the source tree:  sudo ./scripts/install-helper.sh
#   - inside the app:   MacFanSpeed.app/Contents/Resources/install-helper.sh,
#                       launched by the Settings window with an administrator
#                       prompt, on a machine that has no copy of this repo
#
# Reading temperatures and fan speeds needs no privileges. Writing fan speeds
# does, so this installs a small root daemon that performs only that one
# operation and hands the fans back to macOS if the app stops talking to it.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="io.github.bradr23.MacFanSpeed.helper"
BIN_DST="/usr/local/libexec/MacFanSpeedHelper"
PLIST_DST="/Library/LaunchDaemons/$LABEL.plist"

# Locate the payload: beside this script when running from the app bundle,
# otherwise in the build output of the source tree.
if [ -f "$HERE/MacFanSpeedHelper" ]; then
    BIN_SRC="$HERE/MacFanSpeedHelper"
    PLIST_SRC="$HERE/$LABEL.plist"
else
    ROOT="$(cd "$HERE/.." && pwd)"
    BIN_SRC="$ROOT/build/FanHelper"
    PLIST_SRC="$ROOT/Resources/$LABEL.plist"
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must run as root:" >&2
    echo "  sudo $0" >&2
    echo "(or use Install Helper in the app's Settings window)" >&2
    exit 1
fi

if [ ! -f "$BIN_SRC" ]; then
    echo "Helper binary not found at $BIN_SRC" >&2
    echo "Build it first:  ./scripts/build.sh release" >&2
    exit 1
fi
if [ ! -f "$PLIST_SRC" ]; then
    echo "Launch daemon plist not found at $PLIST_SRC" >&2
    exit 1
fi

echo "==> stopping any previous daemon"
launchctl bootout "system/$LABEL" 2>/dev/null || true

echo "==> installing $BIN_DST"
mkdir -p /usr/local/libexec
install -m 755 -o root -g wheel "$BIN_SRC" "$BIN_DST"

echo "==> installing $PLIST_DST"
install -m 644 -o root -g wheel "$PLIST_SRC" "$PLIST_DST"

echo "==> loading daemon"
launchctl bootstrap system "$PLIST_DST"
launchctl enable "system/$LABEL"

sleep 1
if launchctl print "system/$LABEL" >/dev/null 2>&1; then
    echo ""
    echo "Installed. $("$BIN_DST" --version)"
    echo "Manual fan control is now available in the app."
    echo "Log: /var/log/MacFanSpeedHelper.log"
else
    echo "" >&2
    echo "The daemon did not start. Check /var/log/MacFanSpeedHelper.log" >&2
    exit 1
fi
