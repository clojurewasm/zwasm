#!/usr/bin/env bash
# record_comparison.sh — Record cross-runtime benchmark comparison
#
# Measures speed (hyperfine), peak memory (/usr/bin/time), and binary size
# for zwasm and other Wasm runtimes.
#
# Usage:
#   bash bench/record_comparison.sh                                # all 5 runtimes (default)
#   bash bench/record_comparison.sh --rt=zwasm,wasmtime            # specific runtimes
#   bash bench/record_comparison.sh --bench=fib                    # specific benchmark
#   bash bench/record_comparison.sh --quick                        # 1 run, no warmup
#
# Output: bench/runtime_comparison.yaml (overwritten each run)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT="$SCRIPT_DIR/runtime_comparison.yaml"
ZWASM="$PROJECT_ROOT/zig-out/bin/zwasm"
RUNNER="$SCRIPT_DIR/run_wasm.mjs"
RUNNER_WASI="$SCRIPT_DIR/run_wasm_wasi.mjs"

cd "$PROJECT_ROOT"

RUNTIMES="zwasm,wasmtime,wasmer,bun,node"
BENCH_FILTER=""
RUNS=3
WARMUP=1

for arg in "$@"; do
  case "$arg" in
    --rt=*)     RUNTIMES="${arg#--rt=}" ;;
    --bench=*)  BENCH_FILTER="${arg#--bench=}" ;;
    --quick)    RUNS=1; WARMUP=0 ;;
    --runs=*)   RUNS="${arg#--runs=}" ;;
    -h|--help)
      echo "Usage: bash bench/record_comparison.sh [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --rt=RT1,RT2,...  Runtimes (default: all 5)"
      echo "                    Available: zwasm, wasmtime, wasmer, bun, node"
      echo "  --bench=NAME      Specific benchmark"
      echo "  --quick           1 run, no warmup"
      echo "  --runs=N          Hyperfine runs (default: 3)"
      echo "  -h, --help        Show this help"
      exit 0
      ;;
  esac
done

IFS=',' read -ra RT_LIST <<< "$RUNTIMES"

# Validate runtimes
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

# --- Collect runtime info ---
get_version() {
  case "$1" in
    zwasm)    $ZWASM --version 2>/dev/null || echo "dev" ;;
    wasmtime) wasmtime --version 2>&1 | head -1 ;;
    wasmer)   wasmer --version 2>&1 | head -1 ;;
    bun)      echo "bun $(bun --version 2>&1)" ;;
    node)     echo "node $(node --version 2>&1)" ;;
  esac
}

get_binary_path() {
  case "$1" in
    zwasm)    echo "$ZWASM" ;;
    wasmtime) which wasmtime ;;
    wasmer)   which wasmer ;;
    bun)      which bun ;;
    node)     which node ;;
  esac
}

get_binary_size() {
  local path
  path=$(get_binary_path "$1")
  # --dereference follows symlinks to get real binary size
  stat --dereference --format=%s "$path" 2>/dev/null || stat -L -f%z "$path" 2>/dev/null || echo "0"
}

# Build command for a given runtime + benchmark
build_cmd() {
  local rt="$1" wasm="$2" func="$3" args="$4" kind="$5"
  case "$kind" in
    invoke)
      case "$rt" in
        zwasm)    echo "$ZWASM run --invoke $func $wasm $args" ;;
        wasmtime) echo "wasmtime run --invoke $func $wasm $args" ;;
        wasmer)   echo "wasmer run $wasm -i $func $args" ;;
        bun)      echo "bun $RUNNER $wasm $func $args" ;;
        node)     echo "node $RUNNER $wasm $func $args" ;;
      esac
      ;;
    wasi)
      case "$rt" in
        zwasm)    echo "$ZWASM run $wasm" ;;
        wasmtime) echo "wasmtime $wasm" ;;
        wasmer)   echo "wasmer $wasm" ;;
        bun)      echo "bun $RUNNER_WASI $wasm" ;;
        node)     echo "node $RUNNER_WASI $wasm" ;;
      esac
      ;;
  esac
}

# Measure peak memory (bytes) using /usr/bin/time on macOS or GNU time on Linux
measure_memory() {
  local cmd="$1"
  local output
  # Use system time (not shell builtin), capture stderr
  output=$(/usr/bin/time -l sh -c "$cmd" 2>&1 >/dev/null || true)
  echo "$output" | grep "maximum resident set size" | awk '{print $1}'
}

# --- Benchmarks: name:wasm:func:args:type ---
# type: invoke (--invoke func args) or wasi (_start entry point)
# Keep in sync with compare_runtimes.sh and record.sh
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
  # Layer 3: Sightglass shootout (WASI _start)
  "st_fib2:bench/wasm/shootout/shootout-fib2.wasm::_start:wasi"
  "st_sieve:bench/wasm/shootout/shootout-sieve.wasm::_start:wasi"
  "st_nestedloop:bench/wasm/shootout/shootout-nestedloop.wasm::_start:wasi"
  "st_ackermann:bench/wasm/shootout/shootout-ackermann.wasm::_start:wasi"
  # ed25519 excluded (crypto, very slow on interpreter)
  #"st_ed25519:bench/wasm/shootout/shootout-ed25519.wasm::_start:wasi"
  "st_matrix:bench/wasm/shootout/shootout-matrix.wasm::_start:wasi"
)

TMPDIR_BENCH=$(mktemp -d)
trap "rm -rf $TMPDIR_BENCH" EXIT

echo ""
echo "Runtimes: ${RT_LIST[*]}"
echo "Runs: $RUNS, warmup: $WARMUP"
echo ""

# --- Print runtime info ---
echo "Runtime info:"
for rt in "${RT_LIST[@]}"; do
  local_ver=$(get_version "$rt")
  local_size=$(get_binary_size "$rt")
  local_mb=$(python3 -c "print(round($local_size / 1048576, 1))")
  printf "  %-10s %s  (%s MB)\n" "$rt" "$local_ver" "$local_mb"
done
echo ""

# --- Write YAML header ---
DATE=$(date +%Y-%m-%d)
COMMIT=$(git -C "$PROJECT_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")

cat > "$OUTPUT" << HEADER
# Cross-Runtime Benchmark Comparison
# Generated by bench/record_comparison.sh
date: "$DATE"
commit: "$COMMIT"
runs: $RUNS
warmup: $WARMUP
runtimes:
HEADER

for rt in "${RT_LIST[@]}"; do
  local_ver=$(get_version "$rt")
  local_size=$(get_binary_size "$rt")
  local_mb=$(python3 -c "print(round($local_size / 1048576, 1))")
  cat >> "$OUTPUT" << RTEOF
  $rt:
    version: "$local_ver"
    binary_size_bytes: $local_size
    binary_size_mb: $local_mb
RTEOF
done

echo "benchmarks:" >> "$OUTPUT"

# --- Run benchmarks ---
for entry in "${BENCHMARKS[@]}"; do
  IFS=: read -r name wasm func bench_args kind <<< "$entry"

  if [[ -n "$BENCH_FILTER" && "$name" != "$BENCH_FILTER" ]]; then
    continue
  fi

  if [[ ! -f "$wasm" ]]; then
    echo "SKIP $name: $wasm not found"
    continue
  fi

  echo "=== $name ($kind) ==="
  echo "  $name:" >> "$OUTPUT"

  for rt in "${RT_LIST[@]}"; do
    cmd=$(build_cmd "$rt" "$wasm" "$func" "$bench_args" "$kind")
    json_file="$TMPDIR_BENCH/${name}_${rt}.json"

    # Speed: hyperfine
    hyperfine --warmup "$WARMUP" --runs "$RUNS" --export-json "$json_file" "$cmd" >/dev/null 2>&1
    time_ms=$(python3 -c "
import json
with open('$json_file') as f:
    data = json.load(f)
print(round(data['results'][0]['mean'] * 1000, 1))
")

    # Memory: peak RSS (single run)
    mem_bytes=$(measure_memory "$cmd")
    mem_mb=$(python3 -c "print(round(${mem_bytes:-0} / 1048576, 1))")

    printf "  %-10s %8s ms  %6s MB\n" "$rt" "$time_ms" "$mem_mb"

    cat >> "$OUTPUT" << BENCHEOF
    $rt: {time_ms: $time_ms, mem_mb: $mem_mb}
BENCHEOF
  done
  echo ""
done

echo "Results written to $OUTPUT"
