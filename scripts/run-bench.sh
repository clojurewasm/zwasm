#!/usr/bin/env bash
# scripts/run-bench.sh — unified bench entry point.
#
# Thin wrapper around bench/run_bench.sh that resolves repo root via
# scripts/lib/versions.sh and forwards all arguments through. Provided
# so `bash scripts/run-bench.sh` works from any cwd and reads the same
# versions.lock as the rest of the gate runners.
#
# Usage:
#   bash scripts/run-bench.sh             # full bench (5 runs + 3 warmup)
#   bash scripts/run-bench.sh --quick     # 1 run, no warmup
#   bash scripts/run-bench.sh --bench=fib # specific benchmark
#
# All arguments are passed straight to bench/run_bench.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/versions.sh
source "$SCRIPT_DIR/lib/versions.sh"

cd "$ZWASM_REPO_ROOT"
exec bash bench/run_bench.sh "$@"
