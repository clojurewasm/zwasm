#!/usr/bin/env bash
# Run fuzz_loader against all corpus modules.
# Verifies that no module causes a crash (panic/segfault).
#
# Usage: bash test/fuzz/run_corpus.sh [--build] [--verbose]
#   --build:   Build fuzz_loader before running (ReleaseSafe)
#   --verbose: Print each file as it's tested

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
CORPUS_DIR="$SCRIPT_DIR/corpus"
FUZZ_BIN="$PROJECT_DIR/zig-out/bin/fuzz_loader"

BUILD=false
VERBOSE=false
for arg in "$@"; do
    case "$arg" in
        --build) BUILD=true ;;
        --verbose) VERBOSE=true ;;
    esac
done

if [ "$BUILD" = true ] || [ ! -f "$FUZZ_BIN" ]; then
    echo "Building fuzz_loader (ReleaseSafe)..."
    zig build -Doptimize=ReleaseSafe 2>&1 | tail -5
fi

if [ ! -f "$FUZZ_BIN" ]; then
    echo "ERROR: fuzz_loader not found at $FUZZ_BIN"
    echo "Run: zig build"
    exit 1
fi

if [ ! -d "$CORPUS_DIR" ] || [ -z "$(ls "$CORPUS_DIR"/*.wasm 2>/dev/null)" ]; then
    echo "ERROR: No corpus files found in $CORPUS_DIR"
    echo "Run: bash test/fuzz/gen_corpus.sh"
    exit 1
fi

total=0
pass=0
fail=0
crash=0

for f in "$CORPUS_DIR"/*.wasm; do
    total=$((total + 1))
    if "$VERBOSE" = true; then
        printf "  [%4d] %s ... " "$total" "$(basename "$f")"
    fi

    # Run with 2s timeout. Exit codes:
    #   0 = loaded OK (or error returned gracefully)
    #   non-zero but not signal = error returned gracefully (expected for invalid wasm)
    #   signal (crash) = BUG
    if timeout 2 "$FUZZ_BIN" < "$f" 2>/dev/null; then
        pass=$((pass + 1))
        "$VERBOSE" && echo "ok" || true
    else
        exit_code=$?
        if [ "$exit_code" -gt 128 ]; then
            # Killed by signal — this is a crash
            sig=$((exit_code - 128))
            crash=$((crash + 1))
            echo "CRASH: $(basename "$f") (signal $sig)"
        else
            # Non-zero exit = graceful error, expected for invalid modules
            pass=$((pass + 1))
            "$VERBOSE" && echo "ok (error)" || true
        fi
    fi
done

echo ""
echo "=== Corpus Run Summary ==="
echo "Total:   $total"
echo "Pass:    $pass"
echo "Crash:   $crash"
echo ""

if [ "$crash" -gt 0 ]; then
    echo "FAIL: $crash crashes found!"
    exit 1
else
    echo "OK: No crashes."
    exit 0
fi
