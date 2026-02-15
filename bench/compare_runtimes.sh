#!/usr/bin/env bash
# compare_runtimes.sh — Compare zwasm against other Wasm runtimes
#
# Usage:
#   bash bench/compare_runtimes.sh                              # All runtimes, all benchmarks
#   bash bench/compare_runtimes.sh --quick                      # Single run
#   bash bench/compare_runtimes.sh --bench=fib                  # Specific benchmark
#   bash bench/compare_runtimes.sh --rt=zwasm,wasmtime          # Specific runtimes
#   bash bench/compare_runtimes.sh --rt=zwasm,wasmtime,bun,node
#
# Supported runtimes: zwasm, wasmtime, bun, node
#
# Benchmark types:
#   invoke  — calls exported function via --invoke (WAT / TinyGo)
#   wasi    — runs _start entry point (shootout / WASI programs)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

QUICK=0
BENCH=""
RUNTIMES="zwasm,wasmtime"

for arg in "$@"; do
  case "$arg" in
    --quick)    QUICK=1 ;;
    --bench=*)  BENCH="${arg#--bench=}" ;;
    --rt=*)     RUNTIMES="${arg#--rt=}" ;;
    -h|--help)
      echo "Usage: bash bench/compare_runtimes.sh [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --rt=RT1,RT2,...  Runtimes (default: zwasm,wasmtime)"
      echo "                    Available: zwasm, wasmtime, bun, node"
      echo "  --bench=NAME      Specific benchmark"
      echo "  --quick           Single run, no warmup"
      echo ""
      echo "Benchmarks:"
      echo "  Layer 1 (WAT):     fib, tak, sieve, nbody, nqueens"
      echo "  Layer 2 (TinyGo):  tgo_fib, tgo_tak, tgo_arith, tgo_sieve,"
      echo "                     tgo_fib_loop, tgo_gcd, tgo_nqueens,"
      echo "                     tgo_mfr, tgo_list, tgo_rwork, tgo_strops"
      echo "  Layer 3 (Shootout): st_fib2, st_sieve, st_nestedloop,"
      echo "                      st_ackermann, st_matrix"
      echo "  Layer 4 (GC):      gc_alloc, gc_tree"
      exit 0
      ;;
  esac
done

IFS=',' read -ra RT_LIST <<< "$RUNTIMES"

for rt in "${RT_LIST[@]}"; do
  case "$rt" in
    zwasm)    ;;
    wasmtime) command -v wasmtime &>/dev/null || { echo "error: wasmtime not found"; exit 1; } ;;
    bun)      command -v bun      &>/dev/null || { echo "error: bun not found"; exit 1; } ;;
    node)     command -v node     &>/dev/null || { echo "error: node not found"; exit 1; } ;;
    *)        echo "error: unknown runtime '$rt'"; exit 1 ;;
  esac
done

for rt in "${RT_LIST[@]}"; do
  if [[ "$rt" == "zwasm" ]]; then
    echo "Building zwasm (ReleaseSafe)..."
    zig build -Doptimize=ReleaseSafe
    break
  fi
done

echo ""
echo "Runtimes:"
for rt in "${RT_LIST[@]}"; do
  case "$rt" in
    zwasm)    echo "  zwasm:    $(./zig-out/bin/zwasm --version 2>/dev/null || echo 'dev')" ;;
    wasmtime) echo "  wasmtime: $(wasmtime --version 2>&1)" ;;
    bun)      echo "  bun:      $(bun --version 2>&1)" ;;
    node)     echo "  node:     $(node --version 2>&1)" ;;
  esac
done

# Benchmark format: name:wasm:func:args:type
# type: invoke (--invoke func args) or wasi (_start entry point)
BENCHMARKS=(
  # Layer 1: WAT hand-written
  "fib:src/testdata/02_fibonacci.wasm:fib:35:invoke"
  "tak:bench/wasm/tak.wasm:tak:24 16 8:invoke"
  "sieve:bench/wasm/sieve.wasm:sieve:1000000:invoke"
  "nbody:bench/wasm/nbody.wasm:run:1000000:invoke"
  "nqueens:src/testdata/25_nqueens.wasm:nqueens:8:invoke"
  # Layer 2: TinyGo
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
  "gc_alloc:bench/wasm/gc_alloc.wasm:gc_bench:100000:gc_invoke"
  "gc_tree:bench/wasm/gc_tree.wasm:gc_tree_bench:18:gc_invoke"
)

RUNS=3
WARMUP=1
if [[ $QUICK -eq 1 ]]; then
  RUNS=1
  WARMUP=0
fi

# Build command for a runtime+benchmark combination
build_cmd() {
  local rt="$1" wasm="$2" func="$3" bench_args="$4" kind="$5"

  case "$kind" in
    invoke)
      case "$rt" in
        zwasm)    echo "./zig-out/bin/zwasm run --invoke $func $wasm $bench_args" ;;
        wasmtime) echo "wasmtime run --invoke $func $wasm $bench_args" ;;
        bun)      echo "bun bench/run_wasm.mjs $wasm $func $bench_args" ;;
        node)     echo "node bench/run_wasm.mjs $wasm $func $bench_args" ;;
      esac
      ;;
    gc_invoke)
      case "$rt" in
        zwasm)    echo "./zig-out/bin/zwasm run --invoke $func $wasm $bench_args" ;;
        wasmtime) echo "wasmtime run --wasm gc --invoke $func $wasm $bench_args" ;;
        bun)      echo "bun bench/run_wasm.mjs $wasm $func $bench_args" ;;
        node)     echo "node bench/run_wasm.mjs $wasm $func $bench_args" ;;
      esac
      ;;
    wasi)
      case "$rt" in
        zwasm)    echo "./zig-out/bin/zwasm run $wasm" ;;
        wasmtime) echo "wasmtime $wasm" ;;
        bun)      echo "bun bench/run_wasm_wasi.mjs $wasm" ;;
        node)     echo "node bench/run_wasm_wasi.mjs $wasm" ;;
      esac
      ;;
  esac
}

for entry in "${BENCHMARKS[@]}"; do
  IFS=: read -r name wasm func bench_args kind <<< "$entry"

  if [[ -n "$BENCH" && "$name" != "$BENCH" ]]; then
    continue
  fi

  if [[ ! -f "$wasm" ]]; then
    echo "SKIP $name: $wasm not found"
    continue
  fi

  echo ""
  echo "=== $name ($kind) ==="

  cmds=()
  cmd_names=()

  for rt in "${RT_LIST[@]}"; do
    cmd=$(build_cmd "$rt" "$wasm" "$func" "$bench_args" "$kind")
    if [[ -n "$cmd" ]]; then
      cmds+=("$cmd")
      cmd_names+=("$rt")
    fi
  done

  if [[ ${#cmds[@]} -lt 1 ]]; then
    echo "  (no compatible runtimes)"
    continue
  fi

  hyp_args=(--runs "$RUNS" --warmup "$WARMUP")
  for i in "${!cmds[@]}"; do
    hyp_args+=(--command-name "${cmd_names[$i]}")
  done
  for cmd in "${cmds[@]}"; do
    hyp_args+=("$cmd")
  done

  hyperfine "${hyp_args[@]}"
done
