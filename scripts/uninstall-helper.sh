#!/usr/bin/env bash
# Remove the privileged fan control daemon.
#
# Runs from the source tree or from inside the app bundle, same as its installer.
#
# Stopping the daemon is itself the release: on SIGTERM it hands the fans back
# and clears the firmware unlock. The explicit release below is belt and braces
# in case the daemon is already gone.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="io.github.bradr23.MacFanSpeed.helper"
BIN_DST="/usr/local/libexec/MacFanSpeedHelper"
PLIST_DST="/Library/LaunchDaemons/$LABEL.plist"

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must run as root:" >&2
    echo "  sudo $0" >&2
    echo "(or use Remove Helper in the app's Settings window)" >&2
    exit 1
fi

# Find a fanctl to release the fans with. Inside the app bundle it sits beside
# this script in Resources; in the source tree it is in build/.
#
# (A third candidate here previously resolved to build/build/fanctl and could
# never match — harmless, but it meant the source-tree case was silently relying
# on the fallback.)
FANCTL=""
for candidate in "$HERE/fanctl" "$(cd "$HERE/.." 2>/dev/null && pwd)/build/fanctl"; do
    [ -x "$candidate" ] && { FANCTL="$candidate"; break; }
done

if [ -n "$FANCTL" ]; then
    echo "==> returning fans to automatic control"
    "$FANCTL" auto || echo "   (could not run fanctl auto; the daemon releases on stop anyway)"
fi

echo "==> stopping daemon"
launchctl bootout "system/$LABEL" 2>/dev/null || true
sleep 1

echo "==> removing files"
rm -f "$PLIST_DST" "$BIN_DST"

echo ""
if launchctl print "system/$LABEL" >/dev/null 2>&1; then
    echo "WARNING: the daemon is still registered. Try rebooting." >&2
    exit 1
fi
echo "Removed. Fan control is disabled; monitoring still works."
