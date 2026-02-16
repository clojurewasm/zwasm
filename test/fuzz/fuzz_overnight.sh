#!/usr/bin/env bash
# Overnight fuzz campaign runner for zwasm.
#
# Snapshots the current fuzz_loader binary to /tmp so ongoing development
# does not interfere. Results are written to .dev/fuzz-overnight-result.txt
# for the next Claude Code session to pick up.
#
# Usage:
#   bash test/fuzz/fuzz_overnight.sh              # default 660 min (~11h)
#   bash test/fuzz/fuzz_overnight.sh --duration=480  # 8 hours
#
# Run at night:
#   nohup bash test/fuzz/fuzz_overnight.sh > /dev/null 2>&1 &
#
# Check progress:
#   tail -f /tmp/zwasm_fuzz_overnight.log

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
RESULT_FILE="$PROJECT_DIR/.dev/fuzz-overnight-result.txt"
LOG_FILE="/tmp/zwasm_fuzz_overnight.log"
SNAPSHOT_BIN="/tmp/zwasm_fuzz_loader_snapshot"
DURATION=660  # ~11 hours (21:00→08:00)

for arg in "$@"; do
    case "$arg" in
        --duration=*) DURATION="${arg#*=}" ;;
    esac
done

# Step 1: Build ReleaseSafe and snapshot the binary
echo "$(date): Building fuzz_loader (ReleaseSafe)..." | tee "$LOG_FILE"
(cd "$PROJECT_DIR" && zig build -Doptimize=ReleaseSafe 2>&1 | tail -3)
cp "$PROJECT_DIR/zig-out/bin/fuzz_loader" "$SNAPSHOT_BIN"
chmod +x "$SNAPSHOT_BIN"
echo "$(date): Binary snapshot at $SNAPSHOT_BIN" | tee -a "$LOG_FILE"

# Step 2: Run fuzz_campaign.sh with the snapshot binary
# Override FUZZ_BIN via environment (patch the campaign script inline)
export FUZZ_BIN_OVERRIDE="$SNAPSHOT_BIN"

echo "$(date): Starting overnight fuzz campaign (${DURATION} min)..." | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Run campaign, capturing output
bash "$SCRIPT_DIR/fuzz_campaign.sh" --duration="$DURATION" --no-coverage 2>&1 | tee -a "$LOG_FILE"
EXIT_CODE=${PIPESTATUS[0]}

# Step 3: Write result file for next session
{
    echo "# Overnight Fuzz Campaign Result"
    echo ""
    echo "Date: $(date)"
    echo "Duration: ${DURATION} minutes"
    echo "Binary: snapshot from $(date -r "$SNAPSHOT_BIN" '+%Y-%m-%d %H:%M')"
    echo "Git commit: $(cd "$PROJECT_DIR" && git rev-parse --short HEAD)"
    echo ""
    tail -15 "$LOG_FILE" | grep -E "^(Duration|Total|Crashes|PASS|FAIL|Campaign)"
    echo ""
    if [ "$EXIT_CODE" -eq 0 ]; then
        echo "Status: PASS"
    else
        echo "Status: FAIL"
        echo "See crash files in test/fuzz/corpus/crash_*"
    fi
} > "$RESULT_FILE"

echo "" | tee -a "$LOG_FILE"
echo "$(date): Campaign complete. Results in $RESULT_FILE" | tee -a "$LOG_FILE"

# Cleanup snapshot
rm -f "$SNAPSHOT_BIN"

exit "$EXIT_CODE"
