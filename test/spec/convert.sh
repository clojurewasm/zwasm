#!/bin/bash
# Convert WebAssembly spec .wast files to JSON + .wasm using wasm-tools.
# Usage: bash test/spec/convert.sh [/path/to/testsuite]
#
# Requires: wasm-tools (https://github.com/bytecodealliance/wasm-tools)
# Defaults to the git submodule at test/spec/testsuite.
# Produces: test/spec/json/<testname>.json + test/spec/json/<testname>.N.wasm

set -e
cd "$(dirname "$0")/../.."

TESTSUITE="${1:-test/spec/testsuite}"

if [ ! -d "$TESTSUITE" ] || [ -z "$(ls "$TESTSUITE"/*.wast 2>/dev/null)" ]; then
    echo "Testsuite not found at $TESTSUITE"
    echo "Run: git submodule update --init"
    exit 1
fi

if ! command -v wasm-tools &>/dev/null; then
    echo "Error: wasm-tools not found. Install: cargo install wasm-tools"
    exit 1
fi

OUTDIR="test/spec/json"

mkdir -p "$OUTDIR"

# Skip memory64 and threads (not yet supported)
SKIP_PATTERNS="memory64|address64|align64|float_memory64|binary_leb128_64"

CONVERTED=0
SKIPPED=0
FAILED=0

convert_wast() {
    local wast="$1"
    local outname="$2"
    local outdir="$3"

    if wasm-tools json-from-wast "$wast" -o "$outdir/$outname.json" --wasm-dir "$outdir/" 2>/dev/null; then
        CONVERTED=$((CONVERTED + 1))
    else
        echo "WARN: failed to convert $outname.wast"
        FAILED=$((FAILED + 1))
    fi
}

for wast in "$TESTSUITE"/*.wast; do
    name=$(basename "$wast" .wast)

    # Skip unsupported proposals
    if echo "$name" | grep -qE "$SKIP_PATTERNS"; then
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # Skip files with "0" or "1" suffix that are memory64/align64 variants
    if echo "$name" | grep -qE '^(address|align|binary)[0-9]$'; then
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    convert_wast "$wast" "$name" "$OUTDIR"
done

# Multi-memory proposal tests (in subdirectory)
MMDIR="$TESTSUITE/multi-memory"
if [ -d "$MMDIR" ]; then
    for wast in "$MMDIR"/*.wast; do
        name=$(basename "$wast" .wast)
        convert_wast "$wast" "$name" "$OUTDIR"
    done
fi

# Relaxed SIMD proposal tests (in subdirectory)
RSDIR="$TESTSUITE/relaxed-simd"
if [ -d "$RSDIR" ]; then
    for wast in "$RSDIR"/*.wast; do
        name=$(basename "$wast" .wast)
        convert_wast "$wast" "$name" "$OUTDIR"
    done
fi

# GC type-subtyping-invalid (only in external GC spec repo, not yet in main testsuite)
GC_TESTSUITE="${GC_TESTSUITE:-$HOME/Documents/OSS/WebAssembly/gc}"
TSI="$GC_TESTSUITE/test/core/gc/type-subtyping-invalid.wast"
if [ -f "$TSI" ]; then
    convert_wast "$TSI" "type-subtyping-invalid" "$OUTDIR"
fi

echo ""
echo "Converted: $CONVERTED, Skipped: $SKIPPED, Failed: $FAILED"
echo "Output: $OUTDIR/"
