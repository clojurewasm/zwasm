#!/bin/bash
# Fuzz testing for zwasm module loader.
#
# Usage:
#   bash fuzz/run_fuzz.sh                # Quick: 1000 iterations
#   bash fuzz/run_fuzz.sh --long         # Long: 10000 iterations
#   bash fuzz/run_fuzz.sh --seed-only    # Just build corpus, no fuzzing
#
# Requires: wasm-tools (smith, mutate)
# Output: crash files saved to fuzz/crashes/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
FUZZ_BIN="$PROJECT_DIR/zig-out/bin/fuzz_loader"
CORPUS_DIR="$SCRIPT_DIR/corpus"
CRASH_DIR="$SCRIPT_DIR/crashes"

ITERATIONS=1000
SEED_ONLY=false

for arg in "$@"; do
    case $arg in
        --long) ITERATIONS=10000 ;;
        --seed-only) SEED_ONLY=true ;;
    esac
done

# Build fuzz_loader if not present or outdated
if [ ! -f "$FUZZ_BIN" ] || [ "$PROJECT_DIR/src/fuzz_loader.zig" -nt "$FUZZ_BIN" ]; then
    echo "Building fuzz_loader (ReleaseSafe)..."
    (cd "$PROJECT_DIR" && zig build -Doptimize=ReleaseSafe)
fi

# Phase 0: Build seed corpus
build_corpus() {
    mkdir -p "$CORPUS_DIR"

    # Copy existing wasm files (small ones only, <100KB)
    local count=0
    for f in "$PROJECT_DIR"/src/testdata/*.wasm "$PROJECT_DIR"/test/e2e/json/*.wasm; do
        if [ -f "$f" ] && [ "$(wc -c < "$f")" -lt 102400 ]; then
            cp "$f" "$CORPUS_DIR/$(basename "$f")"
            count=$((count + 1))
        fi
    done

    # Generate diverse modules with wasm-tools smith
    for i in $(seq 1 50); do
        SIZE=$((i * 20 + 10))
        head -c $SIZE /dev/urandom | wasm-tools smith -o "$CORPUS_DIR/smith_${i}.wasm" 2>/dev/null || true
    done

    # Minimal valid module (just header)
    printf '\x00\x61\x73\x6d\x01\x00\x00\x00' > "$CORPUS_DIR/minimal.wasm"

    echo "Corpus: $(ls "$CORPUS_DIR"/*.wasm 2>/dev/null | wc -l | tr -d ' ') files"
}

build_corpus

if $SEED_ONLY; then
    echo "Seed corpus built. Exiting."
    exit 0
fi

# Phase 1: Fuzz with corpus seeds
mkdir -p "$CRASH_DIR"
CRASHES=0
RUNS=0

echo "Running $ITERATIONS fuzz iterations..."

TIMEOUT_CMD="timeout"
TIMEOUT_SEC=2

run_one() {
    local input_file="$1"
    local label="$2"
    $TIMEOUT_CMD ${TIMEOUT_SEC}s "$FUZZ_BIN" < "$input_file" 2>/tmp/zwasm_fuzz_err.txt
    local rc=$?
    # timeout(1) returns 124 on timeout — not a crash
    if [ $rc -eq 124 ]; then return; fi
    RUNS=$((RUNS + 1))
    if [ $rc -ne 0 ]; then
        CRASHES=$((CRASHES + 1))
        local crash_name="crash_${RUNS}_${label}.wasm"
        cp "$input_file" "$CRASH_DIR/$crash_name"
        echo "CRASH [$label] ($(wc -c < "$input_file" | tr -d ' ')B): $(head -1 /tmp/zwasm_fuzz_err.txt)"
    fi
}

# Phase 1a: Corpus seeds (existing wasm files)
for f in "$CORPUS_DIR"/*.wasm; do
    [ -f "$f" ] && run_one "$f" "corpus"
done

# Phase 1b: Random bytes
RANDOM_ITERS=$((ITERATIONS / 3))
for i in $(seq 1 $RANDOM_ITERS); do
    SIZE=$((RANDOM % 4000 + 1))
    head -c $SIZE /dev/urandom > /tmp/zwasm_fuzz_input.bin
    run_one /tmp/zwasm_fuzz_input.bin "random"
done

# Phase 1c: wasm-tools smith generated
SMITH_ITERS=$((ITERATIONS / 3))
for i in $(seq 1 $SMITH_ITERS); do
    SIZE=$((RANDOM % 2000 + 10))
    head -c $SIZE /dev/urandom | wasm-tools smith -o /tmp/zwasm_fuzz_smith.wasm 2>/dev/null || continue
    run_one /tmp/zwasm_fuzz_smith.wasm "smith"
done

# Phase 1d: wasm-tools smith + mutate
MUTATE_ITERS=$((ITERATIONS / 3))
for i in $(seq 1 $MUTATE_ITERS); do
    SIZE=$((RANDOM % 1000 + 50))
    head -c $SIZE /dev/urandom | wasm-tools smith 2>/dev/null | \
        wasm-tools mutate --seed $i -o /tmp/zwasm_fuzz_mut.wasm 2>/dev/null || continue
    [ -f /tmp/zwasm_fuzz_mut.wasm ] && run_one /tmp/zwasm_fuzz_mut.wasm "mutate"
done

rm -f /tmp/zwasm_fuzz_input.bin /tmp/zwasm_fuzz_smith.wasm /tmp/zwasm_fuzz_mut.wasm /tmp/zwasm_fuzz_err.txt

echo "========================================"
echo "Results: $RUNS runs, $CRASHES crashes"
if [ $CRASHES -gt 0 ]; then
    echo "Crash files saved to: $CRASH_DIR/"
    ls "$CRASH_DIR"/*.wasm 2>/dev/null
fi
echo "========================================"
