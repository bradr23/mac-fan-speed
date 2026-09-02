#!/usr/bin/env bash
# Verifies presets, persistence and the temperature failsafe.
#
#   ./scripts/verify-safety.sh          (NOT sudo — the helper is already root)
#
# Install the helper first: sudo ./scripts/install-helper.sh, or Settings ›
# Fan Control › Install Helper. The installed daemon must match this tree; the
# script refuses to run otherwise, because a gate that silently tests a stale
# root daemon is worse than no gate.
#
# This script kills any running copy of MacFanSpeed, and rebuilds the app twice.
#
# The failsafe check temporarily lowers the trip threshold to just *below* idle,
# because the real one is 95 °C and reaching that deliberately is not a
# reasonable thing to do to a laptop. Below rather than above matters: manual
# control spins the fans up, which cools the machine, so a threshold above idle
# can never be reached. The whole ladder is moved together — the ceiling and the
# floor — so the patched build stays a configuration the code can actually
# represent. Moving only the ceiling put the reset point *above* the trip, which
# made the app flap trip→release→re-force once per poll and produced a failure
# that was entirely the harness's own doing.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
FANCTL="$ROOT/build/fanctl"
APP="$ROOT/build/MacFanSpeed.app/Contents/MacOS/MacFanSpeed"
FAILSAFE_SRC="Sources/SMCKit/ThermalLimits.swift"
PASS=0; FAIL=0; SKIP=0

green() { printf '\033[32m%s\033[0m\n' "$1"; }
red()   { printf '\033[31m%s\033[0m\n' "$1"; }
amber() { printf '\033[33m%s\033[0m\n' "$1"; }
head2() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
ok()   { green "  PASS  $1"; PASS=$((PASS+1)); }
bad()  { red   "  FAIL  $1"; FAIL=$((FAIL+1)); }
skip() { amber "  SKIP  $1"; SKIP=$((SKIP+1)); }

# ---------------------------------------------------------------- preconditions

# Run as the developer, not as root. Under sudo every file this script writes —
# a tracked source file, the whole signed app bundle, .build — ends up root-owned
# and unwritable afterwards. Nothing here needs root: `helper-auto` goes through
# the daemon, which is already root.
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    red "Run this WITHOUT sudo. The helper is already root, and running as root"
    red "leaves root-owned files in your working tree."
    exit 1
fi

if [ ! -x "$FANCTL" ]; then echo "Build first: ./scripts/build.sh release" >&2; exit 1; fi

# A previous run that was SIGKILLed leaves the tainted source in place and its
# pristine copy in .orig. Detected before anything else, because copying over
# that backup would destroy the only good copy and bake a below-idle ceiling into
# the daemon payload the installer ships.
if [ -f "$FAILSAFE_SRC.orig" ]; then
    red "$FAILSAFE_SRC.orig exists — a previous run did not finish."
    red "Restore it first:  mv $FAILSAFE_SRC.orig $FAILSAFE_SRC && ./scripts/build.sh release"
    exit 1
fi

# ---------------------------------------------------------------- fan helpers

# Every fan, not just the first. Reading one row let a second fan stay forced
# while all three release checks printed PASS, on a machine that has two.
fan_modes() { "$FANCTL" fans | awk 'NR>1 && $1 ~ /^[0-9]+$/ {printf "%s:%s ", $1, $6}'; }

BASELINE_MODES=""
FANLESS=0

record_baseline_modes() {
    stop_app

    # Through the daemon, which is already root — and synchronously, so it does
    # not return until the daemon has finished its restore, firmware wait
    # included. `fanctl auto` writes the SMC directly and needs root, so in the
    # invocation this script documents it failed every single time, silenced by a
    # redirect and swallowed by `|| true`. The net that was supposed to guarantee
    # the fans end in Auto did nothing at all.
    if ! "$FANCTL" helper-auto >/dev/null 2>&1; then
        red "  the helper could not return the fans to automatic control"
        "$FANCTL" helper-auto 2>&1 | sed 's/^/    /'
        exit 1
    fi

    if "$FANCTL" fans 2>&1 | grep -qi "no fans"; then
        FANLESS=1
        return
    fi

    # The baseline has to be read with the fans genuinely at rest — captured
    # mid-manipulation it records the *forced* mode, and every release check
    # below then compares forced against forced and prints PASS. Two positive
    # checks rather than a sleep: `Ftst` clear is evidence the firmware is not
    # yielded, and the modes must read the same twice in a row, so a value the
    # handshake is passing through cannot be mistaken for a resting one.
    local ftst
    ftst="$("$FANCTL" key Ftst 2>/dev/null | sed -n 's/.*value=\([0-9.]*\).*/\1/p')"
    if [ -n "$ftst" ] && [ "$ftst" != "0.00" ]; then
        bad "Ftst reads ${ftst} — the firmware is still yielded, so no resting mode can be read"
        exit 1
    fi

    local deadline=$((SECONDS + 20)) previous=""
    while [ "$SECONDS" -lt "$deadline" ]; do
        BASELINE_MODES="$(fan_modes)"
        if [ -n "$BASELINE_MODES" ] && [ "$BASELINE_MODES" = "$previous" ]; then
            echo "    this Mac rests at fan mode(s) ${BASELINE_MODES}"
            return
        fi
        previous="$BASELINE_MODES"
        sleep 1
    done
    bad "this Mac's fan modes would not settle; the release checks would be meaningless"
    dump_fan_state
    exit 1
}

# Poll until every fan is back at its recorded resting mode.
#
# Never a fixed sleep. The daemon's own restore waits up to reclaimWaitSeconds
# (10) for the firmware, and on the developer's Mac it logs 2.4-3.5 s — so a
# `sleep 3` followed by a single read reported "still forced" for a restore that
# was half a second from finishing.
wait_until_automatic() {
    local deadline=$((SECONDS + ${1:-20})) now
    while [ "$SECONDS" -lt "$deadline" ]; do
        now="$(fan_modes)"
        [ -n "$now" ] && [ "$now" = "$BASELINE_MODES" ] && return 0
        sleep 1
    done
    return 1
}

# Printed whenever a release check fails, so the output says what was actually
# observed instead of only that it did not match.
dump_fan_state() {
    echo "    observed: $(fan_modes)"
    echo "    expected: ${BASELINE_MODES}"
    "$FANCTL" fans 2>&1 | sed 's/^/    /'
    "$FANCTL" key Ftst 2>&1 | sed 's/^/    /'
}

stop_app() {
    pkill -x MacFanSpeed 2>/dev/null || true
    local deadline=$((SECONDS + 10))
    while [ "$SECONDS" -lt "$deadline" ] && pgrep -x MacFanSpeed >/dev/null; do sleep 1; done
}

# ---------------------------------------------------------------- cleanup

CLEANED=0
cleanup() {
    [ "$CLEANED" -eq 1 ] && return
    CLEANED=1

    # Order matters: stop the app that is re-forcing the fans, THEN release them.
    # Releasing first left the app free to take them straight back.
    stop_app
    "$FANCTL" helper-auto >/dev/null 2>&1 || true

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

    # Last word on hard rule 2: say plainly whether the fans came back.
    if [ "$FANLESS" -eq 0 ] && [ -n "$BASELINE_MODES" ]; then
        if wait_until_automatic 20; then
            green "Fans are back under macOS control ($(fan_modes))."
        else
            red "FANS MAY STILL BE FORCED — observed $(fan_modes), expected ${BASELINE_MODES}"
            red "  Recover with:  ./build/fanctl helper-auto"
        fi
    fi
}
# Only EXIT does the work; the signal traps just choose an exit code. The trap
# used to fire cleanup for INT and again for EXIT, running the whole rebuild
# twice on Ctrl-C.
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ---------------------------------------------------------------- helper

head2 "Helper"
if ! "$FANCTL" helper-status; then
    bad "helper not available — install it: sudo ./scripts/install-helper.sh"
    exit 1
fi
ok "helper is installed and responding"

# The gate used to happily test a freshly built app against whatever daemon
# happened to be installed, and did: a 0.5.0 app against a 0.4.0 root daemon,
# with the failure attributed to code that was not running.
INSTALLED="$("$FANCTL" helper-status | awk '/responding/ {print $NF}')"
TREE="$("$FANCTL" version | awk '{print $2}')"
if [ "$INSTALLED" != "$TREE" ]; then
    bad "installed daemon is ${INSTALLED} but this tree is ${TREE}"
    red "  Reinstall it first:  sudo ./scripts/install-helper.sh"
    red "  Testing a new app against an old root daemon proves nothing."
    exit 1
fi
ok "installed daemon (${INSTALLED}) matches this tree"

# ---------------------------------------------------------------- presets

record_baseline_modes

if [ "$FANLESS" -eq 1 ]; then
    head2 "Fans"
    skip "this Mac reports no fans — passively cooled, so the fan tests do not apply"
    echo ""
    echo "Passed: $PASS    Failed: $FAIL    Skipped: $SKIP"
    exit 0
fi

head2 "1. Preset resolves to the fan's own range"
MINRPM="$("$FANCTL" fans | awk 'NR==2 {print $3}')"
MAXRPM="$("$FANCTL" fans | awk 'NR==2 {print $4}')"
EXPECTED=$(( MINRPM + (MAXRPM - MINRPM) * 55 / 100 ))
echo "55% of ${MINRPM}-${MAXRPM} should be about ${EXPECTED} rpm"

stop_app
OUT="$(MFS_TEST_MANUAL=55 "$APP" 2>&1)"
echo "$OUT" | grep -E "requestedRPM|peakRPM|result" | sed 's/^/    /'

# The expected value used to be computed, printed, and never asserted — the
# heading claimed to check that a percentage resolves against each fan's own
# range, and a human reading two adjacent numbers was the only thing checking it.
REQUESTED="$(echo "$OUT" | sed -n 's/^manualtest.requestedRPM: \[\(.*\)\]$/\1/p' | tr -d ' ')"
if [ -z "$REQUESTED" ]; then
    bad "the app did not report what it resolved 55% to"
else
    RESOLVE_OK=1
    IFS=',' read -ra REQ <<< "$REQUESTED"
    for r in "${REQ[@]}"; do
        [ "$r" -ge $((EXPECTED - 2)) ] && [ "$r" -le $((EXPECTED + 2)) ] || RESOLVE_OK=0
    done
    if [ "$RESOLVE_OK" -eq 1 ]; then
        ok "55% resolved to ${REQUESTED} rpm against this Mac's own range"
    else
        bad "55% resolved to ${REQUESTED} rpm, expected about ${EXPECTED} on every fan"
    fi
fi

if echo "$OUT" | grep -q "manualtest.result: PASS"; then
    ok "the app drove the fans to the resolved target"
else
    bad "the app did not reach the resolved target"
fi

head2 "2. Fans released on quit"
# Only meaningful if the app was actually holding the fans when it quit. If the
# failsafe had already released during test 1, the quit-release path never runs
# and a PASS here would claim coverage the run did not get.
if echo "$OUT" | grep -q "manualtest.finalMode: manual"; then
    if wait_until_automatic 20; then
        ok "fans returned to automatic after the app quit"
    else
        bad "fans still forced after the app quit"
        dump_fan_state
    fi
else
    skip "the app was not in manual when it quit, so the quit-release path did not run"
fi

# ---------------------------------------------------------------- failsafe

head2 "3. Failsafe trips and releases"
IDLE="$("$FANCTL" temps --cpu | awk '{print $1}' | cut -d. -f1)"
# Piped straight into arithmetic and into a sed, so it is checked first: an empty
# read or an absurd value used to compile a nonsensical ceiling that the script's
# own post-sed guard then happily accepted.
if ! [[ "$IDLE" =~ ^[0-9]+$ ]] || [ "$IDLE" -lt 20 ] || [ "$IDLE" -gt 99 ]; then
    bad "could not read a plausible CPU temperature (got '${IDLE}'); refusing to patch a threshold"
    exit 1
fi

# Trip *below* idle, not above. Spinning the fans up cools the machine, so a
# threshold above idle can never be reached — an earlier version of this test
# reported a failsafe failure that was really the fans doing their job.
TRIP=$(( IDLE - 3 ))
CRITICAL=$(( TRIP + 5 ))
# The floor moves with the ceiling. Leaving it at 60 while the ceiling dropped to
# 29 made `minimumTrip...maximumTrip` an inverted ClosedRange, which traps at
# runtime — so the safety test compiled a build that could crash the app while it
# held the fans forced, the one state hard rule 2 forbids.
FLOOR=$(( TRIP - 10 ))
echo "Idle is ${IDLE} °C; tripping at ${TRIP} °C so it fires immediately"
echo "(reset lands at ${FLOOR} °C, below idle, so one trip should hold)"

cp "$FAILSAFE_SRC" "$FAILSAFE_SRC.orig"

# These substitutions MUST fail loudly. An earlier version patched a constant
# that had since been renamed: sed matched nothing, exited 0, and the script went
# on to report that the failsafe had not fired — a green-looking run that proved
# nothing at all.
for probe in "assumedCriticalCelsius: Double = 100" "minimumTripCelsius: Double = 60"; do
    if ! grep -q "$probe" "$FAILSAFE_SRC"; then
        red "Cannot find '${probe}' in $FAILSAFE_SRC."
        red "It has been renamed; this script would silently test nothing. Fix it first."
        exit 1
    fi
done
sed -i '' \
    -e "s/assumedCriticalCelsius: Double = 100/assumedCriticalCelsius: Double = ${CRITICAL}/" \
    -e "s/minimumTripCelsius: Double = 60/minimumTripCelsius: Double = ${FLOOR}/" \
    "$FAILSAFE_SRC"
grep -q "assumedCriticalCelsius: Double = ${CRITICAL}" "$FAILSAFE_SRC" \
    && grep -q "minimumTripCelsius: Double = ${FLOOR}" "$FAILSAFE_SRC" || {
    red "The substitution did not apply. Refusing to report a result."
    exit 1
}

# Checked, not assumed. A failed build here left the *previous* binary in place —
# still carrying the real 95 °C ceiling — and the script then reported "failsafe
# did not fire" as a product failure.
if ! ./scripts/build.sh release >/tmp/mfs-verify-build.log 2>&1; then
    bad "the patched build FAILED (see /tmp/mfs-verify-build.log)"
    exit 1
fi

stop_app
OUT="$(MFS_TEST_MANUAL=55 "$APP" 2>&1)"
echo "$OUT" | grep -E "manualtest\.(tripCelsius|t\+|failsafeFired|tripCount|finalMode)" | sed 's/^/    /'

# Close the loop on the rebuild: the binary under test must report the patched
# threshold, so a stale build can never masquerade as a failsafe that did not fire.
SAW_TRIP="$(echo "$OUT" | sed -n 's/^manualtest.tripCelsius: //p')"
if [ "$SAW_TRIP" = "$TRIP" ]; then
    ok "the app under test is using the patched ${TRIP} °C threshold"
else
    bad "the app reports a ${SAW_TRIP} °C threshold but this test patched ${TRIP} °C — stale build"
    exit 1
fi

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

# One trip, held. More than one means the app released and re-forced while the
# machine was still above the cutoff, which is flapping, not recovery.
COUNT="$(echo "$OUT" | sed -n 's/^manualtest.tripCount: //p')"
if [ "$COUNT" = "1" ]; then
    ok "the failsafe tripped once and held"
else
    bad "the failsafe trip/release cycled ${COUNT} times — it should trip once and hold"
fi

if wait_until_automatic 20; then
    ok "fans are under macOS control after the failsafe tripped"
else
    bad "fans still forced after the failsafe tripped"
    dump_fan_state
fi

head2 "Summary"
echo "Passed: $PASS    Failed: $FAIL    Skipped: $SKIP"
echo ""
echo "Not covered here (needs a reboot): with a preset active, quit the app,"
echo "enable Settings › General › Start at login, reboot, and check the menu bar"
echo "comes back with that preset already applied."
[ "$FAIL" -eq 0 ] || exit 1
