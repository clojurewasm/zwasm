#!/usr/bin/env bash
# compare_runtimes.sh — Compare zwasm against other Wasm runtimes
#
# Usage:
#   bash bench/compare_runtimes.sh                              # All runtimes, all benchmarks
#   bash bench/compare_runtimes.sh --quick                      # Single run
#   bash bench/compare_runtimes.sh --bench=fib                  # Specific benchmark
#   bash bench/compare_runtimes.sh --rt=zwasm,wasmtime          # Specific runtimes
#   bash bench/compare_runtimes.sh --rt=zwasm,wasmtime,wasmer   # Mix & match
#
# Supported runtimes: zwasm, wasmtime, wasmer, bun, node
#
# Note: bun/node use bench/run_wasm.mjs wrapper and only work with
# pure-Wasm modules (no WASI imports). TinyGo benchmarks may be skipped.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

QUICK=0
BENCH=""
RUNTIMES="zwasm,wasmtime"  # default

for arg in "$@"; do
  case "$arg" in
    --quick)    QUICK=1 ;;
    --bench=*)  BENCH="${arg#--bench=}" ;;
    --rt=*)     RUNTIMES="${arg#--rt=}" ;;
    -h|--help)
      echo "Usage: bash bench/compare_runtimes.sh [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --rt=RT1,RT2,...  Runtimes to compare (default: zwasm,wasmtime)"
      echo "                    Available: zwasm, wasmtime, wasmer, bun, node"
      echo "  --bench=NAME      Specific benchmark (e.g. fib, sieve, tgo_fib)"
      echo "  --quick           Single run, no warmup"
      echo "  -h, --help        Show this help"
      exit 0
      ;;
  esac
done

# Parse runtime list
IFS=',' read -ra RT_LIST <<< "$RUNTIMES"

# Validate runtimes are available
for rt in "${RT_LIST[@]}"; do
  case "$rt" in
    zwasm)    ;; # built below
    wasmtime) command -v wasmtime &>/dev/null || { echo "error: wasmtime not found"; exit 1; } ;;
    wasmer)   command -v wasmer   &>/dev/null || { echo "error: wasmer not found"; exit 1; } ;;
    bun)      command -v bun      &>/dev/null || { echo "error: bun not found"; exit 1; } ;;
    node)     command -v node     &>/dev/null || { echo "error: node not found"; exit 1; } ;;
    *)        echo "error: unknown runtime '$rt'"; exit 1 ;;
  esac
done

# Build zwasm if needed
for rt in "${RT_LIST[@]}"; do
  if [[ "$rt" == "zwasm" ]]; then
    echo "Building zwasm (ReleaseSafe)..."
    zig build -Doptimize=ReleaseSafe
    break
  fi
done

# Print runtime versions
echo ""
echo "Runtimes:"
for rt in "${RT_LIST[@]}"; do
  case "$rt" in
    zwasm)    echo "  zwasm:    $(./zig-out/bin/zwasm --version 2>/dev/null || echo 'dev')" ;;
    wasmtime) echo "  wasmtime: $(wasmtime --version 2>&1)" ;;
    wasmer)   echo "  wasmer:   $(wasmer --version 2>&1)" ;;
    bun)      echo "  bun:      $(bun --version 2>&1)" ;;
    node)     echo "  node:     $(node --version 2>&1)" ;;
  esac
done

# Benchmark definitions
BENCHMARKS=(
  "fib:src/testdata/02_fibonacci.wasm:fib:35:pure"
  "tak:bench/wasm/tak.wasm:tak:24 16 8:pure"
  "sieve:bench/wasm/sieve.wasm:sieve:1000000:pure"
  "nbody:bench/wasm/nbody.wasm:run:1000000:pure"
  "nqueens:src/testdata/25_nqueens.wasm:nqueens:8:pure"
  "tgo_fib:bench/wasm/tgo_fib.wasm:fib:35:wasi"
  "tgo_tak:bench/wasm/tgo_tak.wasm:tak:24 16 8:wasi"
  "tgo_arith:bench/wasm/tgo_arith.wasm:arith_loop:100000000:wasi"
  "tgo_sieve:bench/wasm/tgo_sieve.wasm:sieve:1000000:wasi"
)

RUNS=3
WARMUP=1
if [[ $QUICK -eq 1 ]]; then
  RUNS=1
  WARMUP=0
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

  echo ""
  echo "=== $name ($kind) ==="

  # Build command list for hyperfine
  cmds=()
  cmd_names=()

  for rt in "${RT_LIST[@]}"; do
    # bun/node can only run pure-wasm (no WASI)
    if [[ "$kind" == "wasi" && ("$rt" == "bun" || "$rt" == "node") ]]; then
      continue
    fi

    case "$rt" in
      zwasm)
        # shellcheck disable=SC2086
        cmds+=("./zig-out/bin/zwasm run --invoke $func $wasm $bench_args")
        cmd_names+=("zwasm")
        ;;
      wasmtime)
        # shellcheck disable=SC2086
        cmds+=("wasmtime run --invoke $func $wasm $bench_args")
        cmd_names+=("wasmtime")
        ;;
      wasmer)
        # shellcheck disable=SC2086
        cmds+=("wasmer run $wasm -i $func $bench_args")
        cmd_names+=("wasmer")
        ;;
      bun)
        # shellcheck disable=SC2086
        cmds+=("bun bench/run_wasm.mjs $wasm $func $bench_args")
        cmd_names+=("bun")
        ;;
      node)
        # shellcheck disable=SC2086
        cmds+=("node bench/run_wasm.mjs $wasm $func $bench_args")
        cmd_names+=("node")
        ;;
    esac
  done

  if [[ ${#cmds[@]} -lt 1 ]]; then
    echo "  (no compatible runtimes for this benchmark)"
    continue
  fi

  # Build hyperfine arguments
  hyp_args=(--runs "$RUNS" --warmup "$WARMUP")
  for i in "${!cmds[@]}"; do
    hyp_args+=(--command-name "${cmd_names[$i]}")
  done
  for cmd in "${cmds[@]}"; do
    hyp_args+=("$cmd")
  done

  hyperfine "${hyp_args[@]}"
done
