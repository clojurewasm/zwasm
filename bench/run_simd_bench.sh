#!/bin/bash
# SIMD microbenchmark suite: scalar vs SIMD comparison
# Usage: bash bench/run_simd_bench.sh [--quick]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ZWASM="$PROJECT_DIR/zig-out/bin/zwasm"
SIMD_DIR="$SCRIPT_DIR/simd"

QUICK=false
if [[ "${1:-}" == "--quick" ]]; then
    QUICK=true
fi

if [[ ! -x "$ZWASM" ]]; then
    echo "Building zwasm (ReleaseSafe)..."
    (cd "$PROJECT_DIR" && zig build -Doptimize=ReleaseSafe)
fi

# Check hyperfine
if ! command -v hyperfine &>/dev/null; then
    echo "ERROR: hyperfine not found. Install: brew install hyperfine"
    exit 1
fi

WARMUP=3
RUNS=10
if $QUICK; then
    WARMUP=1
    RUNS=3
fi

echo "=== SIMD Microbenchmark Suite ==="
echo "Mode: $(if $QUICK; then echo 'quick'; else echo 'full'; fi)"
echo ""

# Benchmark definitions: name, wat_file, scalar_func, simd_func, args
declare -a BENCHES=(
    "dot_product|dot_product.wat|dot_scalar|dot_simd|10000"
    "matrix_mul|matrix_mul.wat|matmul_scalar|matmul_simd|1000"
    "byte_search|byte_search.wat|search_scalar|search_simd|1000 42"
    "image_blend|image_blend.wat|blend_scalar|blend_simd|1000"
)

for bench_spec in "${BENCHES[@]}"; do
    IFS='|' read -r name wat scalar_func simd_func args <<< "$bench_spec"
    wat_path="$SIMD_DIR/$wat"

    echo "=== $name ==="

    # Verify correctness first
    scalar_val=$($ZWASM run --invoke "$scalar_func" "$wat_path" $args 2>&1)
    simd_val=$($ZWASM run --invoke "$simd_func" "$wat_path" $args 2>&1)
    echo "  Verification: scalar=$scalar_val simd=$simd_val"

    # Benchmark scalar
    echo "  Scalar:"
    hyperfine \
        --warmup "$WARMUP" \
        --runs "$RUNS" \
        --command-name "scalar" \
        "$ZWASM run --invoke $scalar_func $wat_path $args" 2>&1 | grep -E "Time|mean"

    # Benchmark SIMD
    echo "  SIMD:"
    hyperfine \
        --warmup "$WARMUP" \
        --runs "$RUNS" \
        --command-name "simd" \
        "$ZWASM run --invoke $simd_func $wat_path $args" 2>&1 | grep -E "Time|mean"

    echo ""
done

echo "=== Done ==="
