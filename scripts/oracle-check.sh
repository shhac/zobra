#!/usr/bin/env bash
# CI / pre-commit: verify our oracle source matches vipvot's canonical copy.
# If a sibling vipvot checkout is present and differs, fail with a diff so
# the user knows to run scripts/oracle-sync.sh.
#
# When vipvot isn't available locally, this is a no-op (succeeds silently)
# so it doesn't block builds for cloners who don't have vipvot.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VIPVOT="${VIPVOT:-$ROOT/../vipvot}"

if [ ! -d "$VIPVOT/oracle" ]; then
    echo "oracle-check: vipvot not found at $VIPVOT/oracle (skipping)"
    exit 0
fi

drift=0
for f in main.go go.mod go.sum; do
    if ! diff -q "$VIPVOT/oracle/$f" "$ROOT/oracle/$f" > /dev/null 2>&1; then
        echo "DRIFT: oracle/$f differs from $VIPVOT/oracle/$f"
        diff "$VIPVOT/oracle/$f" "$ROOT/oracle/$f" || true
        drift=1
    fi
done

if [ "$drift" -ne 0 ]; then
    echo "" >&2
    echo "oracle/ has drifted from vipvot's canonical copy." >&2
    echo "If vipvot moved forward, run: scripts/oracle-sync.sh" >&2
    echo "If zobra is canonical for this change, mirror it back to vipvot first." >&2
    exit 1
fi

echo "oracle-check: in sync with $VIPVOT/oracle/"
