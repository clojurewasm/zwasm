#!/usr/bin/env bash
# record.sh — Record benchmark results to bench/history.yaml
#
# Usage:
#   bash bench/record.sh --id="3.5" --reason="Register IR implementation"
#   bash bench/record.sh --id="3.5" --reason="Register IR" --overwrite
#   bash bench/record.sh --id="3.5" --reason="Register IR" --bench=fib
#   bash bench/record.sh --id="3.5" --reason="Register IR" --runs=10
#   bash bench/record.sh --delete="3.5"
#
# All measurements use: hyperfine (ReleaseSafe, zwasm CLI)
# Results appended to bench/history.yaml

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HISTORY_FILE="$SCRIPT_DIR/history.yaml"
ZWASM="$PROJECT_ROOT/zig-out/bin/zwasm"

# --- Defaults ---
ID=""
REASON=""
OVERWRITE=false
DELETE_ID=""
BENCH_FILTER=""
RUNS=5
WARMUP=2

# --- Benchmark definitions: name:wasm:function:args:type ---
# Keep in sync with run_bench.sh
# type: invoke (--invoke func args) or wasi (_start entry point)
BENCHMARKS=(
  "fib:src/testdata/02_fibonacci.wasm:fib:35:invoke"
  "tak:bench/wasm/tak.wasm:tak:24 16 8:invoke"
  "sieve:bench/wasm/sieve.wasm:sieve:1000000:invoke"
  "nbody:bench/wasm/nbody.wasm:run:1000000:invoke"
  "nqueens:src/testdata/25_nqueens.wasm:nqueens:8:invoke"
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
)

BENCH_ORDER=(fib tak sieve nbody nqueens tgo_fib tgo_tak tgo_arith tgo_sieve tgo_fib_loop tgo_gcd tgo_nqueens tgo_mfr tgo_list tgo_rwork tgo_strops st_fib2 st_sieve st_nestedloop st_ackermann st_matrix gc_alloc gc_tree)

# --- Parse arguments ---
for arg in "$@"; do
  case "$arg" in
    --id=*)       ID="${arg#--id=}" ;;
    --reason=*)   REASON="${arg#--reason=}" ;;
    --overwrite)  OVERWRITE=true ;;
    --delete=*)   DELETE_ID="${arg#--delete=}" ;;
    --bench=*)    BENCH_FILTER="${arg#--bench=}" ;;
    --runs=*)     RUNS="${arg#--runs=}" ;;
    --warmup=*)   WARMUP="${arg#--warmup=}" ;;
    -h|--help)
      echo "Usage: bash bench/record.sh --id=ID --reason=REASON [OPTIONS]"
      echo ""
      echo "Required:"
      echo "  --id=ID           Entry identifier (e.g. '3.5', '3.6-fusion')"
      echo "  --reason=REASON   Why this measurement was taken"
      echo ""
      echo "Options:"
      echo "  --overwrite       Replace existing entry with same id"
      echo "  --delete=ID       Delete entry by id (no benchmark run)"
      echo "  --bench=NAME      Run specific benchmark only (e.g. fib)"
      echo "  --runs=N          Number of hyperfine runs (default: 5)"
      echo "  --warmup=N        Number of warmup runs (default: 2)"
      echo "  -h, --help        Show this help"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 1
      ;;
  esac
done

# --- Delete mode ---
if [[ -n "$DELETE_ID" ]]; then
  if [[ ! -f "$HISTORY_FILE" ]]; then
    echo "No history file found" >&2
    exit 1
  fi
  before=$(yq '.entries | length' "$HISTORY_FILE")
  yq -i "del(.entries[] | select(.id == \"$DELETE_ID\"))" "$HISTORY_FILE"
  after=$(yq '.entries | length' "$HISTORY_FILE")
  if [[ "$before" == "$after" ]]; then
    echo "Entry '$DELETE_ID' not found" >&2
    exit 1
  fi
  echo "Deleted entry '$DELETE_ID' ($before -> $after entries)"
  exit 0
fi

# --- Validate arguments ---
if [[ -z "$ID" || -z "$REASON" ]]; then
  echo "Error: --id and --reason are required" >&2
  echo "Run with --help for usage" >&2
  exit 1
fi

# --- Check for duplicate id ---
if [[ -f "$HISTORY_FILE" ]] && ! $OVERWRITE; then
  existing=$(yq ".entries[] | select(.id == \"$ID\") | .id" "$HISTORY_FILE" 2>/dev/null || echo "")
  if [[ -n "$existing" ]]; then
    echo "Error: Entry '$ID' already exists. Use --overwrite to replace." >&2
    exit 1
  fi
fi

# --- Build ReleaseSafe ---
echo "Building ReleaseSafe..."
(cd "$PROJECT_ROOT" && zig build -Doptimize=ReleaseSafe) || {
  echo "Build failed" >&2
  exit 1
}

echo "Recording: id=$ID reason=\"$REASON\""
echo "Runs=$RUNS, warmup=$WARMUP"
echo ""

# --- Run benchmarks with hyperfine ---
TMPDIR_BENCH=$(mktemp -d)
trap "rm -rf $TMPDIR_BENCH" EXIT

declare -A BENCH_RESULTS  # bench_name -> time_ms

for entry in "${BENCHMARKS[@]}"; do
  IFS=: read -r name wasm func bench_args kind <<< "$entry"

  if [[ -n "$BENCH_FILTER" && "$name" != "$BENCH_FILTER" ]]; then
    continue
  fi

  wasm_path="$PROJECT_ROOT/$wasm"
  if [[ ! -f "$wasm_path" ]]; then
    printf "  %-16s SKIP (not found)\n" "$name"
    continue
  fi

  printf "  %-16s " "$name"

  json_file="$TMPDIR_BENCH/${name}.json"

  # Build command based on type
  if [[ "$kind" == "invoke" ]]; then
    bench_cmd="$ZWASM run --invoke $func $wasm_path $bench_args"
  else
    bench_cmd="$ZWASM run $wasm_path"
  fi

  # shellcheck disable=SC2086
  hyperfine \
    --warmup "$WARMUP" \
    --runs "$RUNS" \
    --export-json "$json_file" \
    "$bench_cmd" \
    >/dev/null 2>&1

  # Parse mean time from JSON (1 decimal place for sub-ms precision)
  time_ms=$(python3 -c "
import json
with open('$json_file') as f:
    data = json.load(f)
r = data['results'][0]
print(round(r['mean'] * 1000, 1))
")

  printf "%8s ms\n" "$time_ms"
  BENCH_RESULTS["$name"]="$time_ms"
done

echo ""

# --- Build entry and write to history.yaml ---
COMMIT=$(git -C "$PROJECT_ROOT" rev-parse --short HEAD)
DATE=$(date +%Y-%m-%d)

# Initialize history file if needed
if [[ ! -f "$HISTORY_FILE" ]]; then
  cat > "$HISTORY_FILE" << 'INITEOF'
# zwasm Benchmark History
# Tracks zwasm performance across optimization tasks.
# All times in milliseconds with 1 decimal place (hyperfine mean).
env:
  cpu: Apple M4 Pro
  ram: 48 GB
  os: Darwin 25.2.0
  tool: hyperfine
entries: []
INITEOF
fi

# Remove existing entry if overwriting
if $OVERWRITE; then
  yq -i "del(.entries[] | select(.id == \"$ID\"))" "$HISTORY_FILE"
fi

# Build YAML entry fragment
ENTRY_FILE=$(mktemp)
cat > "$ENTRY_FILE" << ENTRYEOF
id: "$ID"
date: "$DATE"
reason: "$REASON"
commit: "$COMMIT"
build: ReleaseSafe
results:
ENTRYEOF

for key in "${BENCH_ORDER[@]}"; do
  if [[ -v "BENCH_RESULTS[$key]" ]]; then
    echo "  $key: {time_ms: ${BENCH_RESULTS[$key]}}" >> "$ENTRY_FILE"
  fi
done

# Append entry
yq -i ".entries += [load(\"$ENTRY_FILE\")]" "$HISTORY_FILE"
rm -f "$ENTRY_FILE"

echo "Recorded entry '$ID' (${#BENCH_RESULTS[@]} benchmarks)"
echo "Done. Results in $HISTORY_FILE"
