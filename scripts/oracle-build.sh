#!/usr/bin/env bash
# Build the cobra reference binary used as the differential-testing oracle.
# Requires Go installed locally. The binary is gitignored; only the JSON
# fixtures it produces (under test/fixtures/) are committed.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT/oracle"
mkdir -p bin
go build -o bin/cobra-oracle .
echo "built: $ROOT/oracle/bin/cobra-oracle"
