#!/usr/bin/env bash
# CI benchmark regression detection.
#
# Runs a fast benchmark subset on both the base branch and the current HEAD,
# then compares. Fails if any benchmark regresses by more than the threshold.
#
# Uses git worktree for the base build — never touches the current working tree.
# Safe for fork PRs and any branch topology.
#
# Usage:
#   bash bench/ci_compare.sh                    # compare HEAD vs main
#   bash bench/ci_compare.sh --base=origin/main # explicit base ref
#   bash bench/ci_compare.sh --threshold=25     # 25% regression threshold
#   bash bench/ci_compare.sh --record-only      # no comparison, just run current
#
# Exit: 0 if no regression (or --record-only), 1 if regression detected.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ZWASM="$PROJECT_DIR/zig-out/bin/zwasm"

BASE_REF="origin/main"
THRESHOLD=20
RUNS=3
WARMUP=1
RECORD_ONLY=false
SKIP_BUILD=false

for arg in "$@"; do
    case "$arg" in
        --base=*) BASE_REF="${arg#*=}" ;;
        --threshold=*) THRESHOLD="${arg#*=}" ;;
        --runs=*) RUNS="${arg#*=}" ;;
        --warmup=*) WARMUP="${arg#*=}" ;;
        --record-only) RECORD_ONLY=true ;;
        --skip-build) SKIP_BUILD=true ;;
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
    # Cached variants
    "fib_cached:src/testdata/02_fibonacci.wasm:fib:35:invoke_cached"
    "sieve_cached:bench/wasm/sieve.wasm:sieve:1000000:invoke_cached"
    "nbody_cached:bench/wasm/nbody.wasm:run:1000000:invoke_cached"
    "tgo_fib_cached:bench/wasm/tgo_fib.wasm:fib:35:invoke_cached"
    "st_nestedloop_cached:bench/wasm/shootout/shootout-nestedloop.wasm::_start:wasi_cached"
    "gc_alloc_cached:bench/wasm/gc_alloc.wasm:gc_bench:100000:invoke_cached"
)

TMPDIR_CI=$(mktemp -d)
trap "rm -rf $TMPDIR_CI" EXIT

# Pre-compile all wasm files for cache
precompile_for_cache() {
    local binary="$1"
    local wasm_root="$2"
    rm -rf ~/.cache/zwasm/
    declare -A seen
    for entry in "${BENCHMARKS[@]}"; do
        IFS=: read -r _name wasm _func _args kind <<< "$entry"
        if [[ "$kind" != *_cached ]]; then continue; fi
        local wasm_path="$wasm_root/$wasm"
        if [[ -f "$wasm_path" && -z "${seen[$wasm_path]+x}" ]]; then
            seen["$wasm_path"]=1
            "$binary" compile "$wasm_path" >/dev/null 2>&1 || true
        fi
    done
}

# Run benchmarks for a given binary, write results to file
run_benchmarks() {
    local binary="$1"
    local outfile="$2"
    local wasm_root="$3"

    precompile_for_cache "$binary" "$wasm_root" || true

    for entry in "${BENCHMARKS[@]}"; do
        IFS=: read -r name wasm func bench_args kind <<< "$entry"
        local wasm_path="$wasm_root/$wasm"

        if [[ ! -f "$wasm_path" ]]; then
            echo "  $name: SKIP (not found)" >&2
            continue
        fi

        local json_file="$TMPDIR_CI/${name}_$(basename "$outfile" .txt).json"

        case "$kind" in
            invoke)
                # shellcheck disable=SC2086
                cmd="$binary run --invoke $func $wasm_path $bench_args"
                ;;
            invoke_cached)
                # shellcheck disable=SC2086
                cmd="$binary run --cache --invoke $func $wasm_path $bench_args"
                ;;
            wasi)
                cmd="$binary run $wasm_path"
                ;;
            wasi_cached)
                cmd="$binary run --cache $wasm_path"
                ;;
        esac

        # Verify command works before benchmarking
        # shellcheck disable=SC2086
        if ! $cmd >/dev/null 2>&1; then
            echo "  $name: SKIP (command failed)" >&2
            continue
        fi
        hyperfine --warmup "$WARMUP" --runs "$RUNS" --export-json "$json_file" "$cmd" 2>&1

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

echo "========================================"
echo "CI Benchmark Regression Detection"
echo "========================================"
echo "Current: $(git -C "$PROJECT_DIR" rev-parse --short HEAD)"
echo "Base:    $BASE_REF"
echo "Threshold: ${THRESHOLD}% regression"
echo "Runs: $RUNS, Warmup: $WARMUP"
echo "Record only: $RECORD_ONLY"
echo ""

# Step 1: Build and benchmark current HEAD
echo "[1/3] Building and benchmarking current HEAD..."
if [[ "$SKIP_BUILD" != "true" ]]; then
    (cd "$PROJECT_DIR" && zig build -Doptimize=ReleaseSafe)
fi

if [[ ! -x "$ZWASM" ]]; then
    echo "ERROR: zwasm binary not found at $ZWASM" >&2
    exit 1
fi

CURRENT_RESULTS="$TMPDIR_CI/current.txt"
: > "$CURRENT_RESULTS"
run_benchmarks "$ZWASM" "$CURRENT_RESULTS" "$PROJECT_DIR"
echo "  Done."
echo ""

# Print current results
echo "  Current results:"
while IFS=' ' read -r name time_ms; do
    printf "    %-20s %8s ms\n" "$name" "$time_ms"
done < "$CURRENT_RESULTS"
echo ""

if [[ "$RECORD_ONLY" == "true" ]]; then
    echo "========================================"
    echo "RECORD ONLY: Benchmarks recorded, no comparison."
    exit 0
fi

# Step 2: Build base in a worktree (never touches current working tree)
echo "[2/3] Building base ($BASE_REF) in worktree..."
BASE_WORKTREE="$TMPDIR_CI/base-worktree"
git -C "$PROJECT_DIR" worktree add -q "$BASE_WORKTREE" "$BASE_REF" 2>&1

(cd "$BASE_WORKTREE" && zig build -Doptimize=ReleaseSafe)
cp "$BASE_WORKTREE/zig-out/bin/zwasm" "$TMPDIR_CI/zwasm_base"
# Use base worktree for wasm files (they may differ between branches)
BASE_RESULTS="$TMPDIR_CI/base.txt"
: > "$BASE_RESULTS"
run_benchmarks "$TMPDIR_CI/zwasm_base" "$BASE_RESULTS" "$BASE_WORKTREE"
echo "  Done."
echo ""

# Clean up worktree
git -C "$PROJECT_DIR" worktree remove -f "$BASE_WORKTREE" 2>/dev/null || true

# Step 3: Compare
echo "[3/3] Comparing results..."
echo ""
printf "  %-20s %10s %10s %8s  %s\n" "Benchmark" "Base(ms)" "PR(ms)" "Change" "Status"
printf "  %-20s %10s %10s %8s  %s\n" "---------" "--------" "------" "------" "------"

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

    printf "  %-20s %10s %10s %8s  %s\n" "$name" "$base_ms" "$current_ms" "$change" "$status"
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
