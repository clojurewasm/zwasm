#!/usr/bin/env bash
# CI benchmark regression detection.
#
# Runs a fast benchmark subset on both main and the current branch,
# then compares. Fails if any benchmark regresses by more than the
# threshold (default 20%).
#
# Usage:
#   bash bench/ci_compare.sh                    # compare HEAD vs main
#   bash bench/ci_compare.sh --base=main        # explicit base branch
#   bash bench/ci_compare.sh --threshold=25     # 25% regression threshold
#
# Exit: 0 if no regression, 1 if regression detected.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ZWASM="$PROJECT_DIR/zig-out/bin/zwasm"

BASE_BRANCH="main"
THRESHOLD=20
RUNS=3
WARMUP=1

for arg in "$@"; do
    case "$arg" in
        --base=*) BASE_BRANCH="${arg#*=}" ;;
        --threshold=*) THRESHOLD="${arg#*=}" ;;
        --runs=*) RUNS="${arg#*=}" ;;
        --warmup=*) WARMUP="${arg#*=}" ;;
    esac
done

# Fast representative subset: covers JIT, FP, memory, WASI, GC
BENCHMARKS=(
    "fib:src/testdata/02_fibonacci.wasm:fib:35:invoke"
    "sieve:bench/wasm/sieve.wasm:sieve:1000000:invoke"
    "nbody:bench/wasm/nbody.wasm:run:1000000:invoke"
    "tgo_fib:bench/wasm/tgo_fib.wasm:fib:35:invoke"
    "st_nestedloop:bench/wasm/shootout/shootout-nestedloop.wasm::_start:wasi"
    "gc_alloc:bench/wasm/gc_alloc.wasm:gc_bench:100000:invoke"
)

TMPDIR_CI=$(mktemp -d)
trap "rm -rf $TMPDIR_CI" EXIT

# Run benchmarks for a given binary, write results to file
run_benchmarks() {
    local binary="$1"
    local outfile="$2"

    for entry in "${BENCHMARKS[@]}"; do
        IFS=: read -r name wasm func bench_args kind <<< "$entry"
        local wasm_path="$PROJECT_DIR/$wasm"

        if [[ ! -f "$wasm_path" ]]; then
            echo "  $name: SKIP (not found)" >&2
            continue
        fi

        local json_file="$TMPDIR_CI/${name}_$(basename "$outfile" .txt).json"

        if [[ "$kind" == "invoke" ]]; then
            # shellcheck disable=SC2086
            cmd="$binary run --invoke $func $wasm_path $bench_args"
        else
            cmd="$binary run $wasm_path"
        fi

        # shellcheck disable=SC2086
        hyperfine --warmup "$WARMUP" --runs "$RUNS" --export-json "$json_file" $cmd >/dev/null 2>&1

        local time_ms
        time_ms=$(python3 -c "
import json
with open('$json_file') as f:
    data = json.load(f)
print(round(data['results'][0]['mean'] * 1000, 1))
")
        echo "$name $time_ms" >> "$outfile"
    done
}

# Save current state
CURRENT_BRANCH=$(git -C "$PROJECT_DIR" rev-parse --abbrev-ref HEAD)
CURRENT_COMMIT=$(git -C "$PROJECT_DIR" rev-parse HEAD)

echo "========================================"
echo "CI Benchmark Regression Detection"
echo "========================================"
echo "Current: $CURRENT_BRANCH ($(git -C "$PROJECT_DIR" rev-parse --short HEAD))"
echo "Base:    $BASE_BRANCH"
echo "Threshold: ${THRESHOLD}% regression"
echo "Runs: $RUNS, Warmup: $WARMUP"
echo ""

# Step 1: Build and benchmark base branch
echo "[1/3] Benchmarking base ($BASE_BRANCH)..."
git -C "$PROJECT_DIR" stash -q --include-untracked 2>/dev/null || true
git -C "$PROJECT_DIR" checkout -q "$BASE_BRANCH"
(cd "$PROJECT_DIR" && zig build -Doptimize=ReleaseSafe 2>&1 | tail -1)
cp "$ZWASM" "$TMPDIR_CI/zwasm_base"

BASE_RESULTS="$TMPDIR_CI/base.txt"
: > "$BASE_RESULTS"
run_benchmarks "$TMPDIR_CI/zwasm_base" "$BASE_RESULTS"
echo "  Done."
echo ""

# Step 2: Build and benchmark current branch
echo "[2/3] Benchmarking current ($CURRENT_BRANCH)..."
git -C "$PROJECT_DIR" checkout -q "$CURRENT_COMMIT"
git -C "$PROJECT_DIR" stash pop -q 2>/dev/null || true
(cd "$PROJECT_DIR" && zig build -Doptimize=ReleaseSafe 2>&1 | tail -1)

CURRENT_RESULTS="$TMPDIR_CI/current.txt"
: > "$CURRENT_RESULTS"
run_benchmarks "$ZWASM" "$CURRENT_RESULTS"
echo "  Done."
echo ""

# Step 3: Compare
echo "[3/3] Comparing results..."
echo ""
printf "  %-16s %10s %10s %8s  %s\n" "Benchmark" "Base(ms)" "PR(ms)" "Change" "Status"
printf "  %-16s %10s %10s %8s  %s\n" "---------" "--------" "------" "------" "------"

regressions=0

while IFS=' ' read -r name base_ms; do
    current_ms=$(grep "^$name " "$CURRENT_RESULTS" | awk '{print $2}')
    if [[ -z "$current_ms" ]]; then
        continue
    fi

    change=$(python3 -c "
base = $base_ms
curr = $current_ms
if base > 0:
    pct = ((curr - base) / base) * 100
    print(f'{pct:+.1f}%')
else:
    print('N/A')
")

    is_regression=$(python3 -c "
base = $base_ms
curr = $current_ms
threshold = $THRESHOLD
if base > 0 and ((curr - base) / base) * 100 > threshold:
    print('FAIL')
else:
    print('ok')
")

    if [[ "$is_regression" == "FAIL" ]]; then
        status="REGRESSION"
        regressions=$((regressions + 1))
    else
        status="ok"
    fi

    printf "  %-16s %10s %10s %8s  %s\n" "$name" "$base_ms" "$current_ms" "$change" "$status"
done < "$BASE_RESULTS"

echo ""
echo "========================================"
if [[ "$regressions" -gt 0 ]]; then
    echo "FAIL: $regressions benchmark(s) regressed by >${THRESHOLD}%"
    exit 1
else
    echo "PASS: No regressions detected (threshold: ${THRESHOLD}%)"
    exit 0
fi
