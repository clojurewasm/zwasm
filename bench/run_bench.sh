#!/bin/bash
# zwasm benchmark runner — uses hyperfine for reliable measurements.
# Usage:
#   bash bench/run_bench.sh              # Run all benchmarks (3 runs + 1 warmup)
#   bash bench/run_bench.sh --quick      # Single run, no warmup
#   bash bench/run_bench.sh --bench=fib  # Run specific benchmark
#   bash bench/run_bench.sh --profile    # Show execution profiles

set -euo pipefail
cd "$(dirname "$0")/.."

ZWASM=./zig-out/bin/zwasm
QUICK=0
BENCH=""
PROFILE=0

for arg in "$@"; do
  case "$arg" in
    --quick) QUICK=1 ;;
    --bench=*) BENCH="${arg#--bench=}" ;;
    --profile) PROFILE=1 ;;
  esac
done

# Build ReleaseSafe
echo "Building (ReleaseSafe)..."
zig build -Doptimize=ReleaseSafe

# Benchmark definitions: name:wasm:function:args
# Layer 1: Hand-written WAT (micro benchmarks)
BENCHMARKS=(
  "fib:src/testdata/02_fibonacci.wasm:fib:35"
  "tak:bench/wasm/tak.wasm:tak:24 16 8"
  "sieve:bench/wasm/sieve.wasm:sieve:1000000"
  "nbody:bench/wasm/nbody.wasm:run:1000000"
  "nqueens:src/testdata/25_nqueens.wasm:nqueens:8"
  # Layer 2: TinyGo compiler output
  "tgo_fib:bench/wasm/tgo_fib.wasm:fib:35"
  "tgo_tak:bench/wasm/tgo_tak.wasm:tak:24 16 8"
  "tgo_arith:bench/wasm/tgo_arith.wasm:arith_loop:100000000"
  "tgo_sieve:bench/wasm/tgo_sieve.wasm:sieve:1000000"
)

for entry in "${BENCHMARKS[@]}"; do
  IFS=: read -r name wasm func bench_args <<< "$entry"

  if [[ -n "$BENCH" && "$name" != "$BENCH" ]]; then
    continue
  fi

  if [[ ! -f "$wasm" ]]; then
    echo "SKIP $name: $wasm not found"
    continue
  fi

  if [[ $PROFILE -eq 1 ]]; then
    echo "=== Profile: $name ==="
    # shellcheck disable=SC2086
    $ZWASM run --profile --invoke "$func" "$wasm" $bench_args
    echo
    continue
  fi

  echo "=== $name ==="
  cmd="$ZWASM run --invoke $func $wasm $bench_args"

  if [[ $QUICK -eq 1 ]]; then
    hyperfine --runs 1 --warmup 0 "$cmd"
  else
    hyperfine --runs 3 --warmup 1 "$cmd"
  fi
  echo
done
