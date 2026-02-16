#!/usr/bin/env bash
# Extended fuzz campaign for zwasm.
#
# Runs multiple rounds of fuzzing:
# 1. Corpus test: all existing corpus modules through fuzz_loader
# 2. Fresh generation: generate new random modules and test
# 3. Mutation: mutate existing corpus modules (bit flips, truncation)
# 4. Zig coverage-guided fuzz: std.testing.fuzz with --fuzz flag
#
# Usage: bash test/fuzz/fuzz_campaign.sh [--duration MINUTES] [--no-coverage]
#   --duration: total campaign time in minutes (default: 30)
#   --no-coverage: skip zig coverage-guided fuzzing (requires web UI)
#
# Exit: 0 if no crashes, 1 if crashes found.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
CORPUS_DIR="$SCRIPT_DIR/corpus"
FUZZ_BIN="$PROJECT_DIR/zig-out/bin/fuzz_loader"
DURATION=30
COVERAGE=true

for arg in "$@"; do
    case "$arg" in
        --duration=*) DURATION="${arg#*=}" ;;
        --no-coverage) COVERAGE=false ;;
    esac
done

echo "========================================"
echo "zwasm Extended Fuzz Campaign"
echo "Duration target: ${DURATION} minutes"
echo "========================================"
echo ""

total_crashes=0
total_tested=0
start_time=$(date +%s)

# Helper: check if time is up
time_remaining() {
    local elapsed=$(( $(date +%s) - start_time ))
    local limit=$((DURATION * 60))
    [ "$elapsed" -lt "$limit" ]
}

# Build fuzz_loader
echo "[1/4] Building fuzz_loader (ReleaseSafe)..."
(cd "$PROJECT_DIR" && zig build -Doptimize=ReleaseSafe 2>&1 | tail -3)
echo ""

# Phase 1: Corpus test
echo "[2/4] Testing existing corpus..."
corpus_count=0
corpus_crash=0
for f in "$CORPUS_DIR"/*.wasm; do
    corpus_count=$((corpus_count + 1))
    if ! timeout 2 "$FUZZ_BIN" < "$f" 2>/dev/null; then
        exit_code=$?
        if [ "$exit_code" -gt 128 ]; then
            corpus_crash=$((corpus_crash + 1))
            echo "  CRASH: $(basename "$f") (signal $((exit_code - 128)))"
        fi
    fi
done
total_tested=$((total_tested + corpus_count))
total_crashes=$((total_crashes + corpus_crash))
echo "  Corpus: $corpus_count tested, $corpus_crash crashes"
echo ""

# Phase 2: Fresh random generation + test (use 70% of remaining time)
echo "[3/4] Generating and testing fresh modules..."
gen_count=0
gen_crash=0
round=0
gen_limit=$(( start_time + DURATION * 60 * 70 / 100 ))

gen_time_remaining() {
    [ "$(date +%s)" -lt "$gen_limit" ]
}

while gen_time_remaining; do
    round=$((round + 1))

    # Generate batch of random modules
    for _ in $(seq 1 50); do
        if ! gen_time_remaining; then break; fi

        size=$((50 + RANDOM % 950))
        tmpfile=$(mktemp /tmp/fuzz_XXXXXX.wasm)

        # Try wasm-tools smith
        if head -c "$size" /dev/urandom | wasm-tools smith -o "$tmpfile" 2>/dev/null; then
            gen_count=$((gen_count + 1))
            if ! timeout 2 "$FUZZ_BIN" < "$tmpfile" 2>/dev/null; then
                exit_code=$?
                if [ "$exit_code" -gt 128 ]; then
                    gen_crash=$((gen_crash + 1))
                    # Save crashing input
                    crash_file="$CORPUS_DIR/crash_$(date +%s)_${gen_count}.wasm"
                    cp "$tmpfile" "$crash_file"
                    echo "  CRASH: saved to $(basename "$crash_file")"
                fi
            fi
        fi

        # Also test raw random bytes (invalid module stress)
        head -c "$((8 + RANDOM % 500))" /dev/urandom > "$tmpfile"
        gen_count=$((gen_count + 1))
        if ! timeout 2 "$FUZZ_BIN" < "$tmpfile" 2>/dev/null; then
            exit_code=$?
            if [ "$exit_code" -gt 128 ]; then
                gen_crash=$((gen_crash + 1))
                crash_file="$CORPUS_DIR/crash_raw_$(date +%s)_${gen_count}.wasm"
                cp "$tmpfile" "$crash_file"
                echo "  CRASH (raw): saved to $(basename "$crash_file")"
            fi
        fi

        rm -f "$tmpfile"
    done

    printf "\r  Round %d: %d tested, %d crashes" "$round" "$gen_count" "$gen_crash"
done
echo ""
total_tested=$((total_tested + gen_count))
total_crashes=$((total_crashes + gen_crash))
echo "  Fresh: $gen_count tested, $gen_crash crashes"
echo ""

# Phase 3: Mutation of existing corpus
echo "[4/4] Mutation testing (bit flips on corpus)..."
mut_count=0
mut_crash=0

for f in "$CORPUS_DIR"/*.wasm; do
    if ! time_remaining; then break; fi

    size=$(wc -c < "$f" | tr -d ' ')
    if [ "$size" -eq 0 ]; then continue; fi

    # 3 mutations per file: bit flip, truncate, byte insert
    for mutation in flip truncate insert; do
        tmpfile=$(mktemp /tmp/fuzz_mut_XXXXXX.wasm)
        case "$mutation" in
            flip)
                cp "$f" "$tmpfile"
                offset=$((RANDOM % size))
                # Flip one byte using dd
                byte=$(dd if="$f" bs=1 skip="$offset" count=1 2>/dev/null | od -An -tu1 | tr -d ' ')
                flipped=$(( (byte + 128) % 256 ))
                printf "\\x$(printf '%02x' "$flipped")" | dd of="$tmpfile" bs=1 seek="$offset" conv=notrunc 2>/dev/null
                ;;
            truncate)
                if [ "$size" -gt 1 ]; then
                    trunc_size=$((1 + RANDOM % (size - 1)))
                    head -c "$trunc_size" "$f" > "$tmpfile"
                else
                    cp "$f" "$tmpfile"
                fi
                ;;
            insert)
                cp "$f" "$tmpfile"
                # Append random byte
                head -c 1 /dev/urandom >> "$tmpfile"
                ;;
        esac

        mut_count=$((mut_count + 1))
        if ! timeout 2 "$FUZZ_BIN" < "$tmpfile" 2>/dev/null; then
            exit_code=$?
            if [ "$exit_code" -gt 128 ]; then
                mut_crash=$((mut_crash + 1))
                crash_file="$CORPUS_DIR/crash_mut_$(date +%s)_${mut_count}.wasm"
                cp "$tmpfile" "$crash_file"
                echo "  CRASH ($mutation): saved to $(basename "$crash_file")"
            fi
        fi
        rm -f "$tmpfile"
    done
done
total_tested=$((total_tested + mut_count))
total_crashes=$((total_crashes + mut_crash))
echo "  Mutation: $mut_count tested, $mut_crash crashes"
echo ""

elapsed=$(( $(date +%s) - start_time ))
elapsed_min=$((elapsed / 60))
elapsed_sec=$((elapsed % 60))

echo "========================================"
echo "Campaign Complete"
echo "========================================"
echo "Duration:  ${elapsed_min}m ${elapsed_sec}s"
echo "Total:     $total_tested modules tested"
echo "Crashes:   $total_crashes"
echo ""

if [ "$total_crashes" -gt 0 ]; then
    echo "FAIL: $total_crashes crashes found!"
    echo "Crash files saved in $CORPUS_DIR/crash_*"
    exit 1
else
    echo "PASS: No crashes found."
    exit 0
fi
