#!/usr/bin/env bash
# Build all sightglass shootout benchmarks from C source to WASI .wasm.
#
# Source: https://github.com/bytecodealliance/sightglass
#   C files from: benchmarks/shootout/src/
#   License: Apache-2.0
#
# Modifications from upstream:
#   - sightglass.h: bench_start()/bench_end() replaced with no-op inlines
#     (original uses wasm imports from "bench" module for profiling)
#   - ackermann.c: hardcoded M=3,N=11 inputs (original reads from files)
#
# The resulting .wasm files only need WASI (for printf) and have no external
# bench imports, so they run on any WASI-compatible runtime without stubs:
#   zwasm run shootout-fib2.wasm
#   wasmtime shootout-fib2.wasm
#   wasmer shootout-fib2.wasm
#
# Requires: zig (tested with 0.15.2)
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="$SCRIPT_DIR/../wasm/shootout"
mkdir -p "$OUT_DIR"

SOURCES=(
    ackermann
    base64
    ctype
    ed25519
    fib2
    gimli
    heapsort
    keccak
    matrix
    memmove
    minicsv
    nestedloop
    random
    ratelimit
    seqhash
    sieve
    switch
    xblabla20
    xchacha20
)

CFLAGS="-target wasm32-wasi -O2 -I$SCRIPT_DIR -lc -Wl,--strip-all"

built=0
failed=0

for name in "${SOURCES[@]}"; do
    src="$SCRIPT_DIR/${name}.c"
    out="$OUT_DIR/shootout-${name}.wasm"
    if [ ! -f "$src" ]; then
        echo "SKIP: $src not found"
        continue
    fi
    if zig cc $CFLAGS "$src" -o "$out" 2>/dev/null; then
        size=$(wc -c < "$out")
        echo "  OK: shootout-${name}.wasm (${size} bytes)"
        built=$((built + 1))
    else
        echo "FAIL: shootout-${name}.wasm"
        zig cc $CFLAGS "$src" -o "$out" 2>&1 | head -10 || true
        failed=$((failed + 1))
    fi
done

echo ""
echo "Built: $built / ${#SOURCES[@]}, Failed: $failed"
