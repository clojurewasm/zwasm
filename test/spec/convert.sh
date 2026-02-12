#!/bin/bash
# Convert WebAssembly spec .wast files to JSON + .wasm using wast2json.
# Usage: bash test/spec/convert.sh /path/to/testsuite
#
# Produces: test/spec/json/<testname>.json + test/spec/json/<testname>.N.wasm

set -e
cd "$(dirname "$0")/../.."

TESTSUITE="${1:-/tmp/wasm-testsuite}"
OUTDIR="test/spec/json"

mkdir -p "$OUTDIR"

# MVP core tests (skip GC, memory64, exception-handling, threads, etc.)
SKIP_PATTERNS="gc|array|struct|extern|tag|exception|memory64|address64|align64|binary_leb128_64|annotations|ref_|any_|i31|sub_|type_|table_copy_mixed|table_get_mixed|elem_mixed|br_on_|extern_|multi_memory|rec_|try_|throw_|rethrow_"

CONVERTED=0
SKIPPED=0
FAILED=0

for wast in "$TESTSUITE"/*.wast; do
    name=$(basename "$wast" .wast)

    # Skip non-MVP tests
    if echo "$name" | grep -qE "$SKIP_PATTERNS"; then
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # Skip files with "0" or "1" suffix that are memory64/align64 variants
    if echo "$name" | grep -qE '^(address|align|binary)[0-9]$'; then
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    if wast2json --enable-tail-call "$wast" -o "$OUTDIR/$name.json" 2>/dev/null; then
        CONVERTED=$((CONVERTED + 1))
    else
        echo "WARN: failed to convert $name.wast"
        FAILED=$((FAILED + 1))
    fi
done

echo ""
echo "Converted: $CONVERTED, Skipped: $SKIPPED, Failed: $FAILED"
echo "Output: $OUTDIR/"
