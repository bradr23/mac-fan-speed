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

# `bootout` returns as soon as the signal is sent, not once the job has gone.
# This daemon hands the fans back to macOS on SIGTERM — around 3 s normally, and
# up to about 14 s if the firmware is slow to reclaim them. Bootstrapping while
# the old job is still registered fails with
#
#     Bootstrap failed: 5: Input/output error
#
# which is what updating the helper *while a preset was active* did every time:
# the busier the daemon, the longer it takes to exit, the more certain the race.
# launchd escalates to SIGKILL after its own timeout, so this always terminates.
printf "    waiting for it to exit"
for _ in $(seq 1 150); do
    launchctl print "system/$LABEL" >/dev/null 2>&1 || break
    printf "."
    sleep 0.2
done
echo

echo "==> installing $BIN_DST"
mkdir -p /usr/local/libexec
install -m 755 -o root -g wheel "$BIN_SRC" "$BIN_DST"

echo "==> installing $PLIST_DST"
install -m 644 -o root -g wheel "$PLIST_SRC" "$PLIST_DST"

echo "==> loading daemon"
# Retried rather than attempted once: the wait above covers the common race, but
# launchd can still be finishing with the old job. A failure here leaves the new
# binary installed and nothing running, which is the one outcome that needs a
# second command from the user — so it is worth a few more seconds to avoid.
bootstrap_error=""
bootstrapped=false
for attempt in 1 2 3; do
    if bootstrap_error="$(launchctl bootstrap system "$PLIST_DST" 2>&1)"; then
        bootstrapped=true
        break
    fi
    [ "$attempt" -lt 3 ] && sleep 2
done

if [ "$bootstrapped" != true ]; then
    echo "" >&2
    echo "Could not start the daemon: ${bootstrap_error:-unknown error}" >&2
    echo "" >&2
    echo "The new files are installed; only starting them failed. Try:" >&2
    echo "  sudo launchctl bootout system/$LABEL" >&2
    echo "  sudo launchctl bootstrap system $PLIST_DST" >&2
    echo "Rebooting also loads it, since the daemon starts at boot." >&2
    exit 1
fi

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
