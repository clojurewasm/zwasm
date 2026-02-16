#!/usr/bin/env bash
# Generate fuzz corpus using wasm-tools smith.
#
# Usage: bash test/fuzz/gen_corpus.sh [count]
#   count: number of modules per category (default: 200)
#
# Output: test/fuzz/corpus/*.wasm

set -euo pipefail

COUNT="${1:-200}"
CORPUS_DIR="$(dirname "$0")/corpus"
mkdir -p "$CORPUS_DIR"

echo "Generating fuzz corpus ($COUNT modules per category)..."

gen() {
    local prefix="$1"
    shift
    local i=0
    local fail=0
    while [ "$i" -lt "$COUNT" ]; do
        if head -c $((50 + RANDOM % 450)) /dev/urandom | \
           wasm-tools smith "$@" -o "$CORPUS_DIR/${prefix}_$(printf '%04d' $i).wasm" 2>/dev/null; then
            i=$((i + 1))
            fail=0
        else
            fail=$((fail + 1))
            if [ "$fail" -ge 10 ]; then
                echo "  $prefix: gave up after $i modules ($fail consecutive failures)"
                break
            fi
        fi
    done
    echo "  $prefix: $i modules"
}

# Category 1: MVP baseline (no extra proposals)
gen "mvp" \
    --simd-enabled=false --tail-call-enabled=false --threads-enabled=false \
    --exceptions-enabled=false --gc-enabled=false --memory64-enabled=false \
    --reference-types-enabled=true --bulk-memory-enabled=true

# Category 2: SIMD
gen "simd" \
    --simd-enabled=true --tail-call-enabled=false --threads-enabled=false \
    --exceptions-enabled=false --gc-enabled=false

# Category 3: GC (includes function-references)
gen "gc" \
    --gc-enabled=true --simd-enabled=false --threads-enabled=false \
    --exceptions-enabled=false

# Category 4: Exception handling
gen "eh" \
    --exceptions-enabled=true --simd-enabled=false --threads-enabled=false \
    --gc-enabled=false

# Category 5: Threads
gen "threads" \
    --threads-enabled=true --simd-enabled=false --exceptions-enabled=false \
    --gc-enabled=false

# Category 6: memory64
gen "mem64" \
    --memory64-enabled=true --simd-enabled=false --threads-enabled=false \
    --exceptions-enabled=false --gc-enabled=false

# Category 7: Tail calls
gen "tailcall" \
    --tail-call-enabled=true --simd-enabled=false --threads-enabled=false \
    --exceptions-enabled=false --gc-enabled=false

# Category 8: Kitchen sink (all proposals)
gen "all" \
    --simd-enabled=true --tail-call-enabled=true --threads-enabled=true \
    --exceptions-enabled=true --gc-enabled=true --memory64-enabled=true

# Category 9: Allow invalid function bodies (for decoder/validator stress)
gen "invalid" \
    --allow-invalid-funcs=true --simd-enabled=true --gc-enabled=true \
    --exceptions-enabled=true

total=$(ls "$CORPUS_DIR"/*.wasm 2>/dev/null | wc -l | tr -d ' ')
echo "Done. Total: $total modules in $CORPUS_DIR/"
