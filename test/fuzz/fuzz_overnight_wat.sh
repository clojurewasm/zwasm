#!/usr/bin/env bash
# Overnight WAT fuzz campaign runner for zwasm.
#
# Snapshots the current fuzz_wat_loader binary to /tmp so ongoing development
# does not interfere. Results are written to .dev/fuzz-overnight-wat-result.txt.
#
# Usage:
#   bash test/fuzz/fuzz_overnight_wat.sh              # default 360 min (6h)
#   bash test/fuzz/fuzz_overnight_wat.sh --duration=480  # 8 hours
#
# Run at night:
#   nohup bash test/fuzz/fuzz_overnight_wat.sh > /dev/null 2>&1 &
#
# Check progress:
#   tail -f /tmp/zwasm_fuzz_overnight_wat.log

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
RESULT_FILE="$PROJECT_DIR/.dev/fuzz-overnight-wat-result.txt"
LOG_FILE="/tmp/zwasm_fuzz_overnight_wat.log"
SNAPSHOT_BIN="/tmp/zwasm_fuzz_wat_loader_snapshot"
DURATION=360  # 6 hours

for arg in "$@"; do
    case "$arg" in
        --duration=*) DURATION="${arg#*=}" ;;
    esac
done

# Step 1: Build ReleaseSafe and snapshot the binary
echo "$(date): Building fuzz_wat_loader (ReleaseSafe)..." | tee "$LOG_FILE"
(cd "$PROJECT_DIR" && zig build -Doptimize=ReleaseSafe 2>&1 | tail -3)
cp "$PROJECT_DIR/zig-out/bin/fuzz_wat_loader" "$SNAPSHOT_BIN"
chmod +x "$SNAPSHOT_BIN"
echo "$(date): Binary snapshot at $SNAPSHOT_BIN" | tee -a "$LOG_FILE"

# Step 2: Run fuzz_wat_campaign.sh with the snapshot binary
export FUZZ_BIN_OVERRIDE="$SNAPSHOT_BIN"

echo "$(date): Starting overnight WAT fuzz campaign (${DURATION} min)..." | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

bash "$SCRIPT_DIR/fuzz_wat_campaign.sh" --duration="$DURATION" 2>&1 | tee -a "$LOG_FILE"
EXIT_CODE=${PIPESTATUS[0]}

# Step 3: Write result file
{
    echo "# Overnight WAT Fuzz Campaign Result"
    echo ""
    echo "Date: $(date)"
    echo "Duration: ${DURATION} minutes"
    echo "Binary: snapshot from $(date -r "$SNAPSHOT_BIN" '+%Y-%m-%d %H:%M')"
    echo "Git commit: $(cd "$PROJECT_DIR" && git rev-parse --short HEAD)"
    echo ""
    tail -15 "$LOG_FILE" | grep -E "^(Duration|Total|Crashes|PASS|FAIL|WAT Campaign)"
    echo ""
    if [ "$EXIT_CODE" -eq 0 ]; then
        echo "Status: PASS"
    else
        echo "Status: FAIL"
        echo "See crash files in test/fuzz/corpus_wat/crash_*"
    fi
} > "$RESULT_FILE"

echo "" | tee -a "$LOG_FILE"
echo "$(date): Campaign complete. Results in $RESULT_FILE" | tee -a "$LOG_FILE"

# Cleanup snapshot
rm -f "$SNAPSHOT_BIN"

exit "$EXIT_CODE"
