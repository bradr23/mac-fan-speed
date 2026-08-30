#!/usr/bin/env bash
# Verifies presets, persistence and the temperature failsafe.
#
#   ./scripts/verify-safety.sh          (no sudo — the helper is already root)
#
# Install the helper first, from Settings > Fan Control > Install Helper.
#
# The failsafe check temporarily lowers the trip threshold to just *below* idle,
# because the real one is 95 °C and reaching that deliberately is not a
# reasonable thing to do to a laptop. Below rather than above matters: manual
# control spins the fans up, which cools the machine, so a threshold above idle
# can never be reached. The original value is restored and the result verified
# before the script exits.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
FANCTL="$ROOT/build/fanctl"
APP="$ROOT/build/MacFanSpeed.app/Contents/MacOS/MacFanSpeed"
FAILSAFE_SRC="Sources/MacFanSpeed/Failsafe.swift"
PASS=0; FAIL=0

green() { printf '\033[32m%s\033[0m\n' "$1"; }
red()   { printf '\033[31m%s\033[0m\n' "$1"; }
head2() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
ok()   { green "  PASS  $1"; PASS=$((PASS+1)); }
bad()  { red   "  FAIL  $1"; FAIL=$((FAIL+1)); }

cleanup() {
    # Put the real threshold back no matter how this ends, and rebuild so the
    # binary on disk is never left with a test value baked in.
    if [ -f "$FAILSAFE_SRC.orig" ]; then
        mv "$FAILSAFE_SRC.orig" "$FAILSAFE_SRC"
        echo ""
        echo "Restoring the real 95 °C threshold and rebuilding…"
        ./scripts/build.sh release >/dev/null 2>&1
        grep -q "tripCelsius: Double = 95" "$FAILSAFE_SRC" \
            && green "Failsafe threshold is back to 95 °C." \
            || red "CHECK $FAILSAFE_SRC — the threshold may still be lowered!"
    fi
    "$FANCTL" auto >/dev/null 2>&1 || true
    pkill -x MacFanSpeed 2>/dev/null || true
}
trap cleanup EXIT INT TERM

if [ ! -x "$FANCTL" ]; then echo "Build first: ./scripts/build.sh release" >&2; exit 1; fi

head2 "Helper"
if "$FANCTL" helper-status; then
    ok "helper is installed and responding"
else
    bad "helper not available — install it from Settings › Fan Control first"
    exit 1
fi

# ---------------------------------------------------------------- presets
head2 "1. Preset resolves to the fan's own range"
MINRPM="$("$FANCTL" fans | awk 'NR==2 {print $3}')"
MAXRPM="$("$FANCTL" fans | awk 'NR==2 {print $4}')"
EXPECTED=$(( MINRPM + (MAXRPM - MINRPM) * 55 / 100 ))
echo "55% of ${MINRPM}-${MAXRPM} should be about ${EXPECTED} rpm"

pkill -x MacFanSpeed 2>/dev/null; sleep 1
OUT="$(MFS_TEST_MANUAL=55 "$APP" 2>&1)"
echo "$OUT" | grep -E "requestedRPM|peakRPM|result" | sed 's/^/    /'
if echo "$OUT" | grep -q "manualtest.result: PASS"; then
    ok "the app drove the fans to the resolved target"
else
    bad "the app did not reach the resolved target"
fi

head2 "2. Fans released on quit"
sleep 5
if [ "$("$FANCTL" fans | awk 'NR==2 {print $6}')" = "3" ]; then
    ok "fans returned to automatic after the app quit"
else
    bad "fans still forced after the app quit"
fi

# ---------------------------------------------------------------- failsafe
head2 "3. Failsafe trips and releases"
IDLE="$("$FANCTL" temps --cpu | awk '{print $1}' | cut -d. -f1)"
# Trip *below* idle, not above. Spinning the fans up cools the machine, so a
# threshold above idle can never be reached — the previous version of this test
# reported a failsafe failure that was really the fans doing their job.
TRIP=$(( IDLE - 3 ))
RESET=$(( IDLE - 5 ))
echo "Idle is ${IDLE} °C; tripping at ${TRIP} °C so it fires immediately"

cp "$FAILSAFE_SRC" "$FAILSAFE_SRC.orig"
sed -i '' "s/tripCelsius: Double = 95/tripCelsius: Double = ${TRIP}/" "$FAILSAFE_SRC"
sed -i '' "s/resetCelsius: Double = 85/resetCelsius: Double = ${RESET}/" "$FAILSAFE_SRC"
./scripts/build.sh release >/dev/null 2>&1

OUT="$(MFS_TEST_MANUAL=55 "$APP" 2>&1)"
echo "$OUT" | grep -E "manualtest\.(t\+|failsafeFired|finalMode)" | sed 's/^/    /'
if echo "$OUT" | grep -q "manualtest.failsafeFired: true"; then
    ok "failsafe fired above the threshold"
else
    bad "failsafe did not fire"
fi
if echo "$OUT" | grep -q "manualtest.finalMode: auto"; then
    ok "app forced itself back to automatic"
else
    bad "app stayed in manual after the failsafe"
fi
sleep 3
if [ "$("$FANCTL" fans | awk 'NR==2 {print $6}')" = "3" ]; then
    ok "fans are under macOS control after the failsafe tripped"
else
    bad "fans still forced after the failsafe tripped"
fi

head2 "Summary"
echo "Passed: $PASS    Failed: $FAIL"
echo ""
echo "Not covered here (needs a reboot): with a preset active, quit the app,"
echo "enable Settings › General › Start at login, reboot, and check the menu bar"
echo "comes back with that preset already applied."
[ "$FAIL" -eq 0 ] || exit 1
