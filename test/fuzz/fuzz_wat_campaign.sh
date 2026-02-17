#!/usr/bin/env bash
# WAT-specific fuzz campaign for zwasm.
#
# Exercises the WAT parser by:
# 1. Converting existing .wasm corpus to .wat via wasm-tools, then loading
# 2. Generating fresh .wasm via wasm-tools smith, converting to .wat, testing
# 3. Text-level mutations on .wat files (keyword swap, line removal, etc.)
#
# Usage: bash test/fuzz/fuzz_wat_campaign.sh [--duration=MINUTES]
#   --duration: total campaign time in minutes (default: 30)
#
# Exit: 0 if no crashes, 1 if crashes found.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
CORPUS_DIR="$SCRIPT_DIR/corpus"
WAT_CORPUS_DIR="$SCRIPT_DIR/corpus_wat"
FUZZ_WAT_BIN="${FUZZ_BIN_OVERRIDE:-$PROJECT_DIR/zig-out/bin/fuzz_wat_loader}"
DURATION=30

for arg in "$@"; do
    case "$arg" in
        --duration=*) DURATION="${arg#*=}" ;;
    esac
done

echo "========================================"
echo "zwasm WAT Fuzz Campaign"
echo "Duration target: ${DURATION} minutes"
echo "========================================"
echo ""

total_crashes=0
total_tested=0
start_time=$(date +%s)

time_remaining() {
    local elapsed=$(( $(date +%s) - start_time ))
    local limit=$((DURATION * 60))
    [ "$elapsed" -lt "$limit" ]
}

# Build fuzz_wat_loader
echo "[1/5] Building fuzz_wat_loader (ReleaseSafe)..."
(cd "$PROJECT_DIR" && zig build -Doptimize=ReleaseSafe 2>&1 | tail -3)
echo ""

# Phase 1: Convert .wasm corpus to .wat and test
echo "[2/5] Converting .wasm corpus to .wat..."
mkdir -p "$WAT_CORPUS_DIR"
convert_count=0
convert_fail=0
for f in "$CORPUS_DIR"/*.wasm; do
    base=$(basename "$f" .wasm)
    wat_file="$WAT_CORPUS_DIR/${base}.wat"
    if [ ! -f "$wat_file" ]; then
        if wasm-tools print "$f" > "$wat_file" 2>/dev/null; then
            convert_count=$((convert_count + 1))
        else
            convert_fail=$((convert_fail + 1))
            rm -f "$wat_file"
        fi
    else
        convert_count=$((convert_count + 1))
    fi
done
echo "  Converted: $convert_count, failed: $convert_fail"
echo ""

# Phase 2: Test converted .wat corpus
echo "[3/5] Testing .wat corpus..."
corpus_count=0
corpus_crash=0
for f in "$WAT_CORPUS_DIR"/*.wat; do
    [ -f "$f" ] || continue
    corpus_count=$((corpus_count + 1))
    if ! timeout 5 "$FUZZ_WAT_BIN" < "$f" 2>/dev/null; then
        exit_code=$?
        if [ "$exit_code" -gt 128 ]; then
            corpus_crash=$((corpus_crash + 1))
            echo "  CRASH: $(basename "$f") (signal $((exit_code - 128)))"
            crash_file="$WAT_CORPUS_DIR/crash_$(date +%s)_${corpus_count}.wat"
            cp "$f" "$crash_file"
        fi
    fi
done
total_tested=$((total_tested + corpus_count))
total_crashes=$((total_crashes + corpus_crash))
echo "  Corpus: $corpus_count tested, $corpus_crash crashes"
echo ""

# Phase 3: Fresh generation (.wasm → .wat → test) — use 60% of remaining time
echo "[4/5] Generating fresh modules (.wasm → .wat)..."
gen_count=0
gen_crash=0
round=0
gen_limit=$(( start_time + DURATION * 60 * 80 / 100 ))

gen_time_remaining() {
    [ "$(date +%s)" -lt "$gen_limit" ]
}

while gen_time_remaining; do
    round=$((round + 1))

    for _ in $(seq 1 30); do
        if ! gen_time_remaining; then break; fi

        size=$((50 + RANDOM % 950))
        tmpwasm=$(mktemp /tmp/fuzz_wat_XXXXXX.wasm)
        tmpwat=$(mktemp /tmp/fuzz_wat_XXXXXX.wat)

        # Generate via wasm-tools smith, convert to .wat, test
        if head -c "$size" /dev/urandom | wasm-tools smith -o "$tmpwasm" 2>/dev/null; then
            if wasm-tools print "$tmpwasm" > "$tmpwat" 2>/dev/null; then
                gen_count=$((gen_count + 1))
                if ! timeout 5 "$FUZZ_WAT_BIN" < "$tmpwat" 2>/dev/null; then
                    exit_code=$?
                    if [ "$exit_code" -gt 128 ]; then
                        gen_crash=$((gen_crash + 1))
                        crash_file="$WAT_CORPUS_DIR/crash_gen_$(date +%s)_${gen_count}.wat"
                        cp "$tmpwat" "$crash_file"
                        echo "  CRASH: saved to $(basename "$crash_file")"
                    fi
                fi
            fi
        fi

        # Also test malformed WAT strings
        gen_count=$((gen_count + 1))
        head -c "$((20 + RANDOM % 200))" /dev/urandom > "$tmpwat"
        if ! timeout 2 "$FUZZ_WAT_BIN" < "$tmpwat" 2>/dev/null; then
            exit_code=$?
            if [ "$exit_code" -gt 128 ]; then
                gen_crash=$((gen_crash + 1))
                crash_file="$WAT_CORPUS_DIR/crash_raw_$(date +%s)_${gen_count}.wat"
                cp "$tmpwat" "$crash_file"
                echo "  CRASH (raw): saved to $(basename "$crash_file")"
            fi
        fi

        rm -f "$tmpwasm" "$tmpwat"
    done

    printf "\r  Round %d: %d tested, %d crashes" "$round" "$gen_count" "$gen_crash"
done
echo ""
total_tested=$((total_tested + gen_count))
total_crashes=$((total_crashes + gen_crash))
echo "  Fresh: $gen_count tested, $gen_crash crashes"
echo ""

# Phase 4: Text-level mutations on .wat corpus
echo "[5/5] WAT text mutations..."
mut_count=0
mut_crash=0

# Keywords to inject for mutation
WAT_KEYWORDS=("i32" "i64" "f32" "f64" "v128" "funcref" "externref" "anyref"
              "struct" "array" "rec" "field" "mut" "param" "result" "local"
              "block" "loop" "if" "else" "end" "br" "br_if" "return"
              "call" "drop" "select" "unreachable" "nop" "memory" "table"
              "global" "export" "import" "func" "module" "type" "data" "elem"
              "ref.null" "ref.func" "ref.i31" "i31.get_s" "struct.new" "array.new"
              "shared" "tag" "try_table" "catch")

for f in "$WAT_CORPUS_DIR"/*.wat; do
    [ -f "$f" ] || continue
    if ! time_remaining; then break; fi

    size=$(wc -c < "$f" | tr -d ' ')
    if [ "$size" -eq 0 ] || [ "$size" -gt 50000 ]; then continue; fi
    lines=$(wc -l < "$f" | tr -d ' ')
    if [ "$lines" -eq 0 ]; then continue; fi

    for mutation in keyword_swap line_delete line_duplicate paren_break; do
        if ! time_remaining; then break; fi
        tmpwat=$(mktemp /tmp/fuzz_mut_XXXXXX.wat)

        case "$mutation" in
            keyword_swap)
                # Replace a random keyword with another
                kw_idx=$((RANDOM % ${#WAT_KEYWORDS[@]}))
                new_kw="${WAT_KEYWORDS[$kw_idx]}"
                # Pick a random line and append the keyword
                line_num=$((1 + RANDOM % lines))
                sed "${line_num}s/$/ ${new_kw}/" "$f" > "$tmpwat"
                ;;
            line_delete)
                # Delete a random line
                line_num=$((1 + RANDOM % lines))
                sed "${line_num}d" "$f" > "$tmpwat"
                ;;
            line_duplicate)
                # Duplicate a random line
                line_num=$((1 + RANDOM % lines))
                sed "${line_num}p" "$f" > "$tmpwat"
                ;;
            paren_break)
                # Remove a random closing paren
                cp "$f" "$tmpwat"
                offset=$((RANDOM % size))
                # Replace one ')' with ' ' using perl
                perl -pe "if (\$pos++ == $((offset % 20))) { s/\)/REMOVED/; }" "$tmpwat" > "${tmpwat}.tmp" 2>/dev/null
                mv "${tmpwat}.tmp" "$tmpwat" 2>/dev/null || cp "$f" "$tmpwat"
                ;;
        esac

        mut_count=$((mut_count + 1))
        if ! timeout 3 "$FUZZ_WAT_BIN" < "$tmpwat" 2>/dev/null; then
            exit_code=$?
            if [ "$exit_code" -gt 128 ]; then
                mut_crash=$((mut_crash + 1))
                crash_file="$WAT_CORPUS_DIR/crash_mut_$(date +%s)_${mut_count}.wat"
                cp "$tmpwat" "$crash_file"
                echo "  CRASH ($mutation): saved to $(basename "$crash_file")"
            fi
        fi
        rm -f "$tmpwat" "${tmpwat}.tmp"
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
echo "WAT Campaign Complete"
echo "========================================"
echo "Duration:  ${elapsed_min}m ${elapsed_sec}s"
echo "Total:     $total_tested modules tested"
echo "Crashes:   $total_crashes"
echo ""

if [ "$total_crashes" -gt 0 ]; then
    echo "FAIL: $total_crashes crashes found!"
    echo "Crash files saved in $WAT_CORPUS_DIR/crash_*"
    exit 1
else
    echo "PASS: No crashes found."
    exit 0
fi
