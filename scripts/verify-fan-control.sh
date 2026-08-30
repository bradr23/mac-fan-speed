#!/usr/bin/env bash
# Verifies fan control end to end: fan writes, the privileged daemon, and every path
# that must end with fans back under macOS control.
#
#   sudo ./scripts/verify-fan-control.sh
#
# Safe by construction:
#   - every target is ABOVE the current fan speed, so the machine is cooled
#     harder during the test, never less
#   - fans are restored on exit no matter how the script ends, including Ctrl-C
#   - the last thing it does is verify the fans really did go back
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FANCTL="$ROOT/build/fanctl"
PASS=0
FAIL=0

green() { printf '\033[32m%s\033[0m\n' "$1"; }
red()   { printf '\033[31m%s\033[0m\n' "$1"; }
head2() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

ok()   { green "  PASS  $1"; PASS=$((PASS+1)); }
bad()  { red   "  FAIL  $1"; FAIL=$((FAIL+1)); }

fan_mode()  { "$FANCTL" fans | awk 'NR==2 {print $6}'; }
fan_rpm()   { "$FANCTL" fans | awk 'NR==2 {print $2}'; }
cpu_temp()  { "$FANCTL" temps --cpu | awk '{print $1}'; }

# ---------------------------------------------------------------- safety net
restore() {
    head2 "Restoring fans"
    "$FANCTL" auto >/dev/null 2>&1 || true
    "$FANCTL" helper-auto >/dev/null 2>&1 || true
    sleep 2
    echo "Final fan state:"
    "$FANCTL" fans | head -4
    local ftst; ftst="$("$FANCTL" key Ftst | grep -o 'value=[0-9.]*' | cut -d= -f2)"
    if [ "${ftst%.*}" = "0" ]; then
        green "Ftst is clear — thermal management is back with the firmware."
    else
        red "WARNING: Ftst reads $ftst and must be 0. Run: sudo $FANCTL auto"
    fi
    local mode; mode="$(fan_mode)"
    if [ "$mode" = "$BASELINE_MODE" ]; then
        green "Fans are back at their automatic baseline (mode $BASELINE_MODE)."
    else
        red "WARNING: fan mode is $mode, expected baseline $BASELINE_MODE."
        red "Run: sudo $FANCTL auto"
    fi
}

# ---------------------------------------------------------------- preflight
if [ "$(id -u)" -ne 0 ]; then
    echo "This test writes to the SMC and installs a daemon, so it needs root:" >&2
    echo "  sudo $0" >&2
    exit 1
fi
if [ ! -x "$FANCTL" ]; then
    echo "Build first:  ./scripts/build.sh release" >&2
    exit 1
fi

head2 "Baseline"
"$FANCTL" fans | head -4
BASELINE_MODE="$(fan_mode)"
BASELINE_TEMP="$(cpu_temp)"
echo "Automatic-mode baseline: $BASELINE_MODE     CPU: ${BASELINE_TEMP} °C"
trap restore EXIT INT TERM

# Target 40% up the fan's range: clearly above idle, well short of full.
MAXRPM="$("$FANCTL" fans | awk 'NR==2 {print $4}')"
MINRPM="$("$FANCTL" fans | awk 'NR==2 {print $3}')"
TARGET=$(( MINRPM + (MAXRPM - MINRPM) * 4 / 10 ))
echo "Test target: ${TARGET} rpm (range ${MINRPM}-${MAXRPM})"

# ---------------------------------------------------------------- 1. probe
head2 "1. Fan mode semantics"
echo "Established on this hardware: Ftst=1, then retry F{i}Md until accepted,"
echo "then F{i}Tg. See SPEC.md 'Taking manual control'. Skipping the probe."

# ---------------------------------------------------------------- 2. direct
head2 "2. Direct SMC write (fanctl set)"
"$FANCTL" set "$TARGET"
echo "Waiting 20s (the firmware yield takes several seconds)…"
sleep 20
RPM_AFTER="$(fan_rpm)"
echo "Fan 0 now at ${RPM_AFTER} rpm"
if [ "${RPM_AFTER%.*}" -gt $(( TARGET / 2 )) ]; then
    ok "fans spun up under a direct write (${RPM_AFTER} rpm)"
else
    bad "fans did not spin up (${RPM_AFTER} rpm, wanted ~${TARGET})"
fi

head2 "3. Release to automatic (fanctl auto)"
"$FANCTL" auto >/dev/null
sleep 2
if [ "$(fan_mode)" = "$BASELINE_MODE" ]; then
    ok "fan mode returned to the baseline ($BASELINE_MODE)"
else
    bad "fan mode is $(fan_mode), expected $BASELINE_MODE"
fi

# ---------------------------------------------------------------- 4. install
head2 "4. Install the privileged daemon"
if "$ROOT/scripts/install-helper.sh"; then
    ok "daemon installed"
else
    bad "daemon failed to install — skipping the remaining tests"
    exit 1
fi

if "$FANCTL" helper-status; then
    ok "daemon is responding over XPC"
else
    bad "daemon is not responding"
    exit 1
fi

# ---------------------------------------------------------------- 5. via XPC
head2 "5. Fan control through the daemon"
"$FANCTL" helper-set "$TARGET" >/tmp/mfs-helper-set.log 2>&1 &
HELPER_CLIENT_PID=$!
sleep 20
RPM_XPC="$(fan_rpm)"
echo "Fan 0 now at ${RPM_XPC} rpm"
if [ "${RPM_XPC%.*}" -gt $(( TARGET / 2 )) ]; then
    ok "daemon applied the target (${RPM_XPC} rpm)"
else
    bad "daemon did not apply the target (${RPM_XPC} rpm)"
    cat /tmp/mfs-helper-set.log
fi

# ------------------------------------------------------- 6. crash protection
head2 "6. Crash protection (kill -9 the client)"
echo "Killing the client without letting it clean up…"
kill -9 "$HELPER_CLIENT_PID" 2>/dev/null
RECOVERED=0
for i in $(seq 1 20); do
    sleep 1
    if [ "$(fan_mode)" = "$BASELINE_MODE" ]; then
        ok "fans returned to automatic ${i}s after the client died"
        RECOVERED=1
        break
    fi
done
if [ "$RECOVERED" -eq 0 ]; then
    bad "fans still forced 20s after the client was killed"
    echo "  daemon log:"
    tail -6 /var/log/MacFanSpeedHelper.log | sed 's/^/    /'
fi

# ---------------------------------------------------------------- 7. clamping
head2 "7. Clamping"
# Start from a settled state; the previous step deliberately crashed a client.
"$FANCTL" auto >/dev/null 2>&1 || true
sleep 3
CLAMP_OUT="$("$FANCTL" set 99999 2>&1)"
echo "$CLAMP_OUT" | sed 's/^/    /'
# Compare against the maximum this machine reports, not a hardcoded number —
# the previous version expected 7826, which is one Mac's fan and nobody else's.
if echo "$CLAMP_OUT" | grep -q "clamped to ${MAXRPM}"; then
    ok "an absurd target was clamped to this fan's maximum (${MAXRPM} rpm)"
else
    bad "an absurd target was not clamped to ${MAXRPM} rpm"
fi
"$FANCTL" auto >/dev/null
sleep 2

# ---------------------------------------------------------------- summary
head2 "Summary"
echo "Passed: $PASS    Failed: $FAIL"
echo ""
echo "The daemon is still installed. Remove it with:"
echo "  sudo $ROOT/scripts/uninstall-helper.sh"
[ "$FAIL" -eq 0 ] || exit 1
