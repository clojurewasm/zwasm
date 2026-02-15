#!/bin/bash
# Differential testing: zwasm vs wasmtime
#
# Generates wasm modules with wasm-tools smith, runs exported zero-arg
# functions in both runtimes, and compares results.
#
# Usage:
#   bash fuzz/diff_test.sh              # 200 iterations
#   bash fuzz/diff_test.sh --long       # 2000 iterations
#
# Requires: wasm-tools, wasmtime

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ZWASM="$PROJECT_DIR/zig-out/bin/zwasm"
MISMATCH_DIR="$SCRIPT_DIR/mismatches"

ITERATIONS=200

for arg in "$@"; do
    case $arg in
        --long) ITERATIONS=2000 ;;
    esac
done

# Build zwasm if needed
if [ ! -f "$ZWASM" ] || [ "$PROJECT_DIR/src/cli.zig" -nt "$ZWASM" ]; then
    echo "Building zwasm (ReleaseSafe)..."
    (cd "$PROJECT_DIR" && zig build -Doptimize=ReleaseSafe)
fi

mkdir -p "$MISMATCH_DIR"
MISMATCHES=0
RUNS=0
TIMEOUT=5

echo "Running $ITERATIONS differential test iterations..."

for i in $(seq 1 $ITERATIONS); do
    # Generate a valid wasm module — no advanced proposals for wasmtime compat
    SIZE=$((RANDOM % 3000 + 200))
    head -c $SIZE /dev/urandom | wasm-tools smith \
        --export-everything true \
        --min-funcs 2 \
        --max-imports 0 \
        --gc-enabled false \
        --reference-types-enabled false \
        --exceptions-enabled false \
        --memory64-enabled false \
        -o /tmp/diff_test.wasm 2>/dev/null || continue

    # Extract ASCII-safe exported function names
    EXPORTS=$(wasm-tools dump /tmp/diff_test.wasm 2>/dev/null | \
        grep 'kind: Func' | \
        sed -n 's/.*name: "\([^"]*\)".*/\1/p' | \
        grep -E '^[a-zA-Z0-9_.-]+$' | head -3 || true)

    [ -z "$EXPORTS" ] && continue

    for func in $EXPORTS; do
        # Run in both runtimes (zero-arg invocation)
        WT_OUT=$(timeout $TIMEOUT wasmtime run --invoke "$func" /tmp/diff_test.wasm 2>&1) || true
        ZW_OUT=$(timeout $TIMEOUT "$ZWASM" run --invoke "$func" /tmp/diff_test.wasm 2>&1) || true

        RUNS=$((RUNS + 1))

        # Strip wasmtime warnings
        WT_CLEAN=$(echo "$WT_OUT" | grep -v "^warning:")
        ZW_CLEAN="$ZW_OUT"

        # Classify: error or success
        WT_ERR=false
        ZW_ERR=false
        echo "$WT_CLEAN" | grep -qiE "error|trap|fault|panic|failed" && WT_ERR=true
        echo "$ZW_CLEAN" | grep -qiE "error|trap|fault|panic|failed|StackOverflow|Unreachable|OutOfBounds" && ZW_ERR=true

        if $WT_ERR && $ZW_ERR; then
            continue  # Both error — OK
        fi

        if ! $WT_ERR && $ZW_ERR; then
            # wasmtime OK, zwasm error — potential bug
            MISMATCHES=$((MISMATCHES + 1))
            cp /tmp/diff_test.wasm "$MISMATCH_DIR/mismatch_${i}_${func}.wasm"
            echo "MISMATCH [$i] $func: wasmtime OK, zwasm error"
            echo "  wasmtime: $(echo "$WT_CLEAN" | head -1)"
            echo "  zwasm:    $(echo "$ZW_CLEAN" | head -1)"
        elif ! $WT_ERR && ! $ZW_ERR; then
            # Both succeed — compare numeric results
            WT_NUMS=$(echo "$WT_CLEAN" | tr -d '[:space:]')
            ZW_NUMS=$(echo "$ZW_CLEAN" | tr -d '[:space:]')
            if [ "$WT_NUMS" != "$ZW_NUMS" ]; then
                MISMATCHES=$((MISMATCHES + 1))
                cp /tmp/diff_test.wasm "$MISMATCH_DIR/mismatch_${i}_${func}.wasm"
                echo "MISMATCH [$i] $func: different results"
                echo "  wasmtime: $WT_NUMS"
                echo "  zwasm:    $ZW_NUMS"
            fi
        fi
        # zwasm OK but wasmtime error — less concerning, skip
    done
done

rm -f /tmp/diff_test.wasm

echo "========================================"
echo "Results: $RUNS invocations, $MISMATCHES mismatches"
if [ $MISMATCHES -gt 0 ]; then
    echo "Mismatch files saved to: $MISMATCH_DIR/"
fi
echo "========================================"
