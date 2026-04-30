#!/usr/bin/env bash
# scripts/run_spec.sh — convenience wrapper for `zig build test-spec`.
#
# Phase 0: stub (no spec runner yet).
# Phase 1+: shells out to `zig build test-spec`.

set -euo pipefail
cd "$(dirname "$0")/.."

if zig build --help 2>&1 | grep -q test-spec; then
    exec zig build test-spec "$@"
fi

echo "[run_spec] no test-spec step yet — Phase 1+."
exit 0
