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

# Benchmark format: name:wasm:function:args:type
# type: invoke (--invoke func args) or wasi (_start entry point)
BENCHMARKS=(
  # Layer 1: Hand-written WAT (micro benchmarks)
  "fib:src/testdata/02_fibonacci.wasm:fib:35:invoke"
  "tak:bench/wasm/tak.wasm:tak:24 16 8:invoke"
  "sieve:bench/wasm/sieve.wasm:sieve:1000000:invoke"
  "nbody:bench/wasm/nbody.wasm:run:1000000:invoke"
  "nqueens:src/testdata/25_nqueens.wasm:nqueens:8:invoke"
  # Layer 2: TinyGo compiler output
  "tgo_fib:bench/wasm/tgo_fib.wasm:fib:35:invoke"
  "tgo_tak:bench/wasm/tgo_tak.wasm:tak:24 16 8:invoke"
  "tgo_arith:bench/wasm/tgo_arith.wasm:arith_loop:100000000:invoke"
  "tgo_sieve:bench/wasm/tgo_sieve.wasm:sieve:1000000:invoke"
  "tgo_fib_loop:bench/wasm/tgo_fib_loop.wasm:fib_loop:25:invoke"
  "tgo_gcd:bench/wasm/tgo_gcd.wasm:gcd:12345 67890:invoke"
  # Layer 3: Sightglass shootout (WASI _start)
  "st_fib2:bench/wasm/shootout/shootout-fib2.wasm::_start:wasi"
  "st_sieve:bench/wasm/shootout/shootout-sieve.wasm::_start:wasi"
  "st_nestedloop:bench/wasm/shootout/shootout-nestedloop.wasm::_start:wasi"
  "st_ackermann:bench/wasm/shootout/shootout-ackermann.wasm::_start:wasi"
  "st_ed25519:bench/wasm/shootout/shootout-ed25519.wasm::_start:wasi"
  "st_matrix:bench/wasm/shootout/shootout-matrix.wasm::_start:wasi"
)

for entry in "${BENCHMARKS[@]}"; do
  IFS=: read -r name wasm func bench_args kind <<< "$entry"

  if [[ -n "$BENCH" && "$name" != "$BENCH" ]]; then
    continue
  fi

  if [[ ! -f "$wasm" ]]; then
    echo "SKIP $name: $wasm not found"
    continue
  fi

  if [[ $PROFILE -eq 1 && "$kind" == "invoke" ]]; then
    echo "=== Profile: $name ==="
    # shellcheck disable=SC2086
    $ZWASM run --profile --invoke "$func" "$wasm" $bench_args
    echo
    continue
  fi

  echo "=== $name ==="
  if [[ "$kind" == "invoke" ]]; then
    cmd="$ZWASM run --invoke $func $wasm $bench_args"
  else
    cmd="$ZWASM run $wasm"
  fi

  if [[ $QUICK -eq 1 ]]; then
    hyperfine --runs 1 --warmup 0 "$cmd"
  else
    hyperfine --runs 3 --warmup 1 "$cmd"
  fi
  echo
done
