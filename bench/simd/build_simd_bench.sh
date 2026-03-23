#!/bin/bash
# Build real-world SIMD benchmark wasm binaries
# Requires: wasm32-wasi-clang (from wasi-sdk)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/src"
OUT_DIR="$SCRIPT_DIR/../wasm/simd"

mkdir -p "$OUT_DIR"

CC=wasm32-wasi-clang
CFLAGS="-O2 -msimd128"

SOURCES=(
    grayscale
    box_blur
    sum_reduce
    byte_freq
    nbody_simd
)

echo "=== Building SIMD benchmarks ==="
for name in "${SOURCES[@]}"; do
    src="$SRC_DIR/${name}.c"
    out="$OUT_DIR/${name}.wasm"
    if [[ ! -f "$src" ]]; then
        echo "SKIP $name: $src not found"
        continue
    fi
    echo "  $name.c -> $name.wasm"
    $CC $CFLAGS -o "$out" "$src" -lm
done

echo ""
echo "Built $(ls "$OUT_DIR"/*.wasm 2>/dev/null | wc -l | tr -d ' ') wasm files in $OUT_DIR"
ls -la "$OUT_DIR"/*.wasm
