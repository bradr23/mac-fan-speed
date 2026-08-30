#!/usr/bin/env bash
# Build, kill any running copy, and launch the menu bar app.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

"$ROOT/scripts/build.sh" "${1:-release}"

pkill -x MacFanSpeed 2>/dev/null || true
sleep 0.5
open build/MacFanSpeed.app
echo "==> launched (look in the menu bar; 'pkill -x MacFanSpeed' to stop)"
