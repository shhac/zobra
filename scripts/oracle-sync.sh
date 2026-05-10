#!/usr/bin/env bash
# Sync the oracle source and fixtures from the canonical vipvot copy.
#
# vipvot is the canonical source of truth for the cobra-reference binary
# (and its captured JSON fixtures). zobra mirrors them. See
# design-docs/05-oracle-testing.md for the rationale.
#
# Usage:
#   scripts/oracle-sync.sh                # use ../vipvot as the source
#   VIPVOT=/path/to/vipvot scripts/oracle-sync.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VIPVOT="${VIPVOT:-$ROOT/../vipvot}"

if [ ! -d "$VIPVOT/oracle" ]; then
    echo "error: vipvot oracle not found at $VIPVOT/oracle" >&2
    echo "       set VIPVOT=/path/to/vipvot or clone vipvot as a sibling" >&2
    exit 1
fi

mkdir -p "$ROOT/oracle"
cp "$VIPVOT/oracle/main.go" "$ROOT/oracle/main.go"
cp "$VIPVOT/oracle/go.mod"  "$ROOT/oracle/go.mod"
cp "$VIPVOT/oracle/go.sum"  "$ROOT/oracle/go.sum"
echo "synced oracle source from $VIPVOT/oracle/"

# Fixtures only sync if vipvot has them. Phase 0: vipvot's fixture format
# is JSON committed under test/fixtures/; we mirror as-is.
if [ -d "$VIPVOT/test/fixtures" ]; then
    mkdir -p "$ROOT/test/fixtures"
    rsync -a --delete "$VIPVOT/test/fixtures/" "$ROOT/test/fixtures/"
    echo "synced fixtures from $VIPVOT/test/fixtures/"
fi
