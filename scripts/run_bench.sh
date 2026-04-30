#!/usr/bin/env bash
# scripts/run_bench.sh — local interactive bench runner.
#
# Phase 0-9: stub. Phase 10+ wires hyperfine against bench/runners/*.wasm.
#
# Usage:
#   bash scripts/run_bench.sh             # full hyperfine (5 runs + 3 warmup)
#   bash scripts/run_bench.sh --quick     # quick (3 runs + 1 warmup)

set -euo pipefail
cd "$(dirname "$0")/.."

QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1

if [ ! -d bench/runners ] || [ -z "$(ls bench/runners/*.wasm 2>/dev/null)" ]; then
    echo "[run_bench] no bench/runners/*.wasm yet — Phase 10+ work."
    exit 0
fi

# TODO(p10): wire hyperfine here.
echo "[run_bench] (Phase 0-9 stub, quick=$QUICK)"
