#!/bin/bash
# zwasm vs wasmtime comparison benchmark
# Usage:
#   bash bench/compare_wasmtime.sh              # All benchmarks (3 runs + 1 warmup)
#   bash bench/compare_wasmtime.sh --quick      # Single run
#   bash bench/compare_wasmtime.sh --bench=fib  # Specific benchmark

set -euo pipefail
cd "$(dirname "$0")/.."

QUICK=0
BENCH=""

for arg in "$@"; do
  case "$arg" in
    --quick) QUICK=1 ;;
    --bench=*) BENCH="${arg#--bench=}" ;;
  esac
done

if ! command -v wasmtime &>/dev/null; then
  echo "error: wasmtime not found in PATH"
  exit 1
fi

echo "Building zwasm (ReleaseSafe)..."
zig build -Doptimize=ReleaseSafe

BENCHMARKS=(
  # Layer 1: Hand-written WAT
  "fib:src/testdata/02_fibonacci.wasm:fib:35"
  "tak:bench/wasm/tak.wasm:tak:24 16 8"
  "sieve:bench/wasm/sieve.wasm:sieve:1000000"
  "nbody:bench/wasm/nbody.wasm:run:1000000"
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

  echo ""
  echo "=== $name ==="
  zwasm_cmd="./zig-out/bin/zwasm run --invoke $func $wasm $bench_args"
  wt_cmd="wasmtime run --invoke $func $wasm $bench_args"

  if [[ $QUICK -eq 1 ]]; then
    hyperfine --runs 1 --warmup 0 \
      --command-name "zwasm" --command-name "wasmtime" \
      "$zwasm_cmd" "$wt_cmd"
  else
    hyperfine --runs 3 --warmup 1 \
      --command-name "zwasm" --command-name "wasmtime" \
      "$zwasm_cmd" "$wt_cmd"
  fi
done
