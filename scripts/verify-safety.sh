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
# The resting fan mode is hardware-specific — 3 on this Mac16,8, and the project's
# own rules say never to assume it. Hardcoding 3 made both release checks fail on
# any Mac that rests at a different value, reporting a correct restore as broken.
# The baseline is therefore recorded before anything is written.
#
# It also has to be recorded with the fans genuinely at rest. Read while a copy
# of the app was still holding Manual — the likely state, since this script is
# what you run to check manual control — it captured the *forced* mode, and both
# release checks below then compared forced against forced and printed PASS. The
# acceptance gate for hard rule 2 reported the failure it exists to catch as a
# success, so the fans are handed back and given time to settle first.
BASELINE_MODE=""
record_baseline_mode() {
    pkill -x MacFanSpeed 2>/dev/null || true
    sleep 2
    "$FANCTL" auto >/dev/null 2>&1 || true
    sleep 3
    BASELINE_MODE="$("$FANCTL" fans | awk 'NR==2 {print $6}')"
    if [ -z "$BASELINE_MODE" ]; then
        bad "could not read this Mac's resting fan mode; the release checks would be meaningless"
        exit 1
    fi
    echo "    this Mac rests at fan mode ${BASELINE_MODE}"
}
fans_are_automatic() {
    local now
    now="$("$FANCTL" fans | awk 'NR==2 {print $6}')"
    [ -n "$BASELINE_MODE" ] && [ "$now" = "$BASELINE_MODE" ]
}

FAILSAFE_SRC="Sources/SMCKit/ThermalLimits.swift"
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
        echo "Restoring the real threshold and rebuilding…"

        # The rebuild's exit status is checked, not assumed. Restoring the source
        # and reporting success while the *build* had failed left the test's
        # below-idle ceiling compiled into build/FanHelper and into the helper
        # payload inside MacFanSpeed.app — which is exactly what Install Helper
        # would then have put on the machine as root.
        local built=0
        ./scripts/build.sh release >/tmp/mfs-verify-rebuild.log 2>&1 || built=$?

        local source_ok=1
        grep -q "assumedCriticalCelsius: Double = 100" "$FAILSAFE_SRC" || source_ok=0

        if [ "$source_ok" -eq 1 ] && [ "$built" -eq 0 ]; then
            green "Failsafe threshold restored and rebuilt."
        else
            red "THE TEST THRESHOLD MAY STILL BE IN YOUR BUILD."
            [ "$source_ok" -eq 1 ] || red "  source: $FAILSAFE_SRC is not restored"
            [ "$built" -eq 0 ] || red "  rebuild FAILED (see /tmp/mfs-verify-rebuild.log)"
            red "  Fix with:  git checkout $FAILSAFE_SRC && ./scripts/build.sh release"
            red "  Do not install the helper from this build until you have."
        fi
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
record_baseline_mode

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
if fans_are_automatic; then
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

# A previous run that was SIGKILLed leaves the tainted source in place and its
# pristine copy in .orig. Copying over that backup would destroy the only good
# copy and bake a below-idle ceiling into the daemon payload the installer ships.
if [ -f "$FAILSAFE_SRC.orig" ]; then
    red "$FAILSAFE_SRC.orig already exists — a previous run did not finish."
    red "Restore it first:  mv $FAILSAFE_SRC.orig $FAILSAFE_SRC && ./scripts/build.sh release"
    exit 1
fi
cp "$FAILSAFE_SRC" "$FAILSAFE_SRC.orig"

# The trip point is derived: maximumTrip = assumedCritical - 5, and the default
# is the maximum. Moving the one assumption therefore moves the whole ladder,
# including past the 60 °C floor, because clampTrip lands on the maximum when the
# maximum is the lower of the two bounds.
#
# This substitution MUST fail loudly. An earlier version patched a constant that
# had since been renamed: sed matched nothing, exited 0, and the script went on
# to report that the failsafe had not fired — a green-looking run that proved
# nothing at all.
if ! grep -q "assumedCriticalCelsius: Double = 100" "$FAILSAFE_SRC"; then
    red "Cannot find the threshold constant in $FAILSAFE_SRC."
    red "It has been renamed; this script would silently test nothing. Fix it first."
    exit 1
fi
sed -i '' "s/assumedCriticalCelsius: Double = 100/assumedCriticalCelsius: Double = $(( TRIP + 5 ))/" "$FAILSAFE_SRC"
grep -q "assumedCriticalCelsius: Double = $(( TRIP + 5 ))" "$FAILSAFE_SRC" || {
    red "The substitution did not apply. Refusing to report a result."
    exit 1
}
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
if fans_are_automatic; then
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
