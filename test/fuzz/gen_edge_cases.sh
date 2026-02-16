#!/usr/bin/env bash
# Generate hand-crafted edge-case wasm seeds for fuzzing.
# These cover known tricky patterns: deeply nested blocks, many locals,
# large function bodies, many imports/exports, etc.
#
# Usage: bash test/fuzz/gen_edge_cases.sh

set -euo pipefail

CORPUS_DIR="$(dirname "$0")/corpus"
mkdir -p "$CORPUS_DIR"

echo "Generating edge-case seeds..."

# Helper: write raw bytes to a file
write_bytes() {
    local file="$1"
    shift
    printf '%b' "$@" > "$file"
}

# 1. Empty module (just header)
write_bytes "$CORPUS_DIR/edge_empty.wasm" '\x00\x61\x73\x6d\x01\x00\x00\x00'

# 2. Module with only a custom section
write_bytes "$CORPUS_DIR/edge_custom_section.wasm" \
    '\x00\x61\x73\x6d\x01\x00\x00\x00' \
    '\x00\x05\x04name\x00'

# 3. Truncated header (3 bytes)
write_bytes "$CORPUS_DIR/edge_truncated_header.wasm" '\x00\x61\x73'

# 4. Wrong magic
write_bytes "$CORPUS_DIR/edge_bad_magic.wasm" '\xDE\xAD\xBE\xEF\x01\x00\x00\x00'

# 5. Wrong version
write_bytes "$CORPUS_DIR/edge_bad_version.wasm" '\x00\x61\x73\x6d\x02\x00\x00\x00'

# 6. Zero-length file
: > "$CORPUS_DIR/edge_zero.wasm"

# 7. Single byte
write_bytes "$CORPUS_DIR/edge_one_byte.wasm" '\xFF'

# 8. Oversized LEB128 (section length)
write_bytes "$CORPUS_DIR/edge_oversized_leb.wasm" \
    '\x00\x61\x73\x6d\x01\x00\x00\x00' \
    '\x01\x80\x80\x80\x80\x80\x00'

# 9. Duplicate sections (two type sections)
write_bytes "$CORPUS_DIR/edge_dup_sections.wasm" \
    '\x00\x61\x73\x6d\x01\x00\x00\x00' \
    '\x01\x04\x01\x60\x00\x00' \
    '\x01\x04\x01\x60\x00\x00'

# 10. Section with content but wrong length (too long)
write_bytes "$CORPUS_DIR/edge_section_overrun.wasm" \
    '\x00\x61\x73\x6d\x01\x00\x00\x00' \
    '\x01\xFF\x01\x60\x00\x00'

# Use wasm-tools to generate some specific patterns
if command -v wasm-tools &>/dev/null; then
    # 11-20: Various seed sizes to exercise different paths
    for size in 1 2 4 8 16 32 64 128 256 512 1024 2048; do
        head -c "$size" /dev/urandom | \
            wasm-tools smith -o "$CORPUS_DIR/edge_seed_${size}b.wasm" 2>/dev/null || true
    done

    # 21-25: Smith with extreme config
    head -c 100 /dev/urandom | wasm-tools smith \
        --min-funcs=0 --max-funcs=0 \
        -o "$CORPUS_DIR/edge_no_funcs.wasm" 2>/dev/null || true

    head -c 500 /dev/urandom | wasm-tools smith \
        --min-funcs=50 --max-funcs=100 \
        -o "$CORPUS_DIR/edge_many_funcs.wasm" 2>/dev/null || true

    head -c 200 /dev/urandom | wasm-tools smith \
        --max-memories=5 --memory64-enabled=true \
        -o "$CORPUS_DIR/edge_multi_memory.wasm" 2>/dev/null || true

    head -c 200 /dev/urandom | wasm-tools smith \
        --max-tables=10 \
        -o "$CORPUS_DIR/edge_multi_table.wasm" 2>/dev/null || true
fi

total=$(ls "$CORPUS_DIR"/edge_*.wasm 2>/dev/null | wc -l | tr -d ' ')
echo "Done. $total edge-case seeds in $CORPUS_DIR/"
