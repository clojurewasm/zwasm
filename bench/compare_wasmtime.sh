#!/bin/bash
# zwasm vs wasmtime comparison benchmark
# Usage: bash bench/compare_wasmtime.sh [--quick]

set -e
cd "$(dirname "$0")/.."

QUICK=false
if [ "$1" = "--quick" ]; then
    QUICK=true
fi

echo "Building zwasm (ReleaseSafe)..."
zig build -Doptimize=ReleaseSafe

echo ""
echo "=== zwasm vs wasmtime: fib(35) ==="
echo ""

WASM_FILE="src/testdata/02_fibonacci.wasm"

if [ "$QUICK" = true ]; then
    hyperfine --warmup 1 --runs 1 \
        "./zig-out/bin/zwasm run --invoke fib $WASM_FILE 35" \
        "wasmtime run --invoke fib $WASM_FILE 35"
else
    hyperfine --warmup 2 --runs 5 \
        --command-name "zwasm (interpreter)" \
        --command-name "wasmtime (JIT)" \
        "./zig-out/bin/zwasm run --invoke fib $WASM_FILE 35" \
        "wasmtime run --invoke fib $WASM_FILE 35"
fi
