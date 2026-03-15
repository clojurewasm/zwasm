#!/bin/bash
# zwasm benchmark runner — uses hyperfine for reliable measurements.
# Usage:
#   bash bench/run_bench.sh              # Run all benchmarks (5 runs + 3 warmup)
#   bash bench/run_bench.sh --quick      # Single run, no warmup
#   bash bench/run_bench.sh --bench=fib  # Run specific benchmark
#   bash bench/run_bench.sh --profile    # Show execution profiles
#   bash bench/run_bench.sh --no-cache   # Skip cached variants

set -euo pipefail
cd "$(dirname "$0")/.."

ZWASM=./zig-out/bin/zwasm
QUICK=0
BENCH=""
PROFILE=0
NO_CACHE=0

for arg in "$@"; do
  case "$arg" in
    --quick) QUICK=1 ;;
    --bench=*) BENCH="${arg#--bench=}" ;;
    --profile) PROFILE=1 ;;
    --no-cache) NO_CACHE=1 ;;
  esac
done

# Build ReleaseSafe
echo "Building (ReleaseSafe)..."
zig build -Doptimize=ReleaseSafe

# Pre-compile for cached benchmarks
precompile_for_cache() {
  echo "Pre-compiling modules for cache..."
  rm -rf ~/.cache/zwasm/
  # Collect unique wasm files from BENCHMARKS
  local seen_list=""
  for entry in "${BENCHMARKS[@]}"; do
    IFS=: read -r _name wasm _func _args _kind <<< "$entry"
    if [[ -n "$BENCH" && "$_name" != "$BENCH" ]]; then continue; fi
    if [[ ! -f "$wasm" ]]; then continue; fi
    case "$seen_list" in *"|$wasm|"*) continue ;; esac
    seen_list="${seen_list}|${wasm}|"
    $ZWASM compile "$wasm" >/dev/null 2>&1 || true
  done
  echo ""
}

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
  "tgo_nqueens:bench/wasm/tgo_nqueens.wasm:nqueens:1000:invoke"
  "tgo_mfr:bench/wasm/tgo_mfr.wasm:mfr:100000:invoke"
  "tgo_list:bench/wasm/tgo_list_build.wasm:list_build:100000:invoke"
  "tgo_rwork:bench/wasm/tgo_real_work.wasm:real_work:2000000:invoke"
  "tgo_strops:bench/wasm/tgo_string_ops.wasm:string_ops:10000000:invoke"
  # Layer 3: Sightglass shootout (WASI _start)
  "st_fib2:bench/wasm/shootout/shootout-fib2.wasm::_start:wasi"
  "st_sieve:bench/wasm/shootout/shootout-sieve.wasm::_start:wasi"
  "st_nestedloop:bench/wasm/shootout/shootout-nestedloop.wasm::_start:wasi"
  "st_ackermann:bench/wasm/shootout/shootout-ackermann.wasm::_start:wasi"
  # ed25519 excluded (crypto, very slow on interpreter)
  #"st_ed25519:bench/wasm/shootout/shootout-ed25519.wasm::_start:wasi"
  "st_matrix:bench/wasm/shootout/shootout-matrix.wasm::_start:wasi"
  # Layer 4: GC proposal (struct/ref types)
  "gc_alloc:bench/wasm/gc_alloc.wasm:gc_bench:100000:invoke"
  "gc_tree:bench/wasm/gc_tree.wasm:gc_tree_bench:18:invoke"
  # Layer 5: Real-world (Rust, C, C++ WASI programs)
  "rw_rust_fib:test/realworld/wasm/rust_fib_compute.wasm::_start:wasi"
  "rw_c_matrix:test/realworld/wasm/c_matrix_multiply.wasm::_start:wasi"
  "rw_c_math:test/realworld/wasm/c_math_compute.wasm::_start:wasi"
  "rw_c_string:test/realworld/wasm/c_string_processing.wasm::_start:wasi"
  "rw_cpp_string:test/realworld/wasm/cpp_string_ops.wasm::_start:wasi"
  "rw_cpp_sort:test/realworld/wasm/cpp_vector_sort.wasm::_start:wasi"
)

# Pre-compile if cache variants enabled
if [[ $NO_CACHE -eq 0 ]]; then
  precompile_for_cache
fi

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

  # Uncached run
  echo "=== $name ==="
  if [[ "$kind" == "invoke" ]]; then
    cmd="$ZWASM run --invoke $func $wasm $bench_args"
  else
    cmd="$ZWASM run $wasm"
  fi

  if [[ $QUICK -eq 1 ]]; then
    hyperfine --runs 1 --warmup 0 "$cmd"
  else
    hyperfine --runs 5 --warmup 3 "$cmd"
  fi
  echo

  # Cached run
  if [[ $NO_CACHE -eq 0 ]]; then
    echo "=== ${name}_cached ==="
    if [[ "$kind" == "invoke" ]]; then
      cmd_cached="$ZWASM run --cache --invoke $func $wasm $bench_args"
    else
      cmd_cached="$ZWASM run --cache $wasm"
    fi

    if [[ $QUICK -eq 1 ]]; then
      hyperfine --runs 1 --warmup 0 "$cmd_cached"
    else
      hyperfine --runs 5 --warmup 3 "$cmd_cached"
    fi
    echo
  fi
done
