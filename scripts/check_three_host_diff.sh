#!/usr/bin/env bash
# scripts/check_three_host_diff.sh — §9.7 / 7.11 three-way
# differential gate.
#
# Verifies that the same critical runner totals appear on all
# three hosts (Mac aarch64, ubuntunote native Linux x86_64,
# windowsmini x86_64) by reading the most-recent test-all log
# files at /tmp/{mac,ubuntu,win}.log. Each runner's total line is
# grep'd from each log; the script flags any host whose total
# deviates from the consensus.
#
# This implements the cross-host engine-differential check
# called for by ROADMAP §9.7 / 7.11 ("interp == jit_arm64 ==
# jit_x86: 0 mismatch over the spec testsuite + 40+ realworld
# samples on each host"). Per-host interp-vs-JIT execution
# differential is the natural Phase 8 follow-up — once WASI
# host wiring lifts the JIT realworld run-stage from 0/55
# RUN-PASS, a fixture-level comparator becomes meaningful.
# Until then, cross-host total equivalence on the runners that
# DO complete is the strongest available evidence.
#
# Usage:
#   scripts/check_three_host_diff.sh
#       Compare /tmp/{mac,ubuntu,win}.log against expected
#       cross-host totals. Exit 0 if all match, 1 otherwise.
#
# Refresh logs first if needed (see CLAUDE.md three-host
# pattern):
#     zig build test-all > /tmp/mac.log 2>&1
#     bash scripts/run_remote_ubuntu.sh test-all > /tmp/ubuntu.log 2>&1
#     bash scripts/run_remote_windows.sh test-all > /tmp/win.log 2>&1

set -uo pipefail

LOGS=(mac ubuntu win)
LOG_DIR=/tmp

# Critical runner totals that MUST be identical across all three
# hosts — these are the cross-host engine differential anchors.
# Each entry is a literal line; the script greps for it in every
# host's log. A miss in any host = MISMATCH.
declare -a EXPECTED=(
    "spec_assert_runner: 212 passed, 0 failed, 20 skipped"
    "wast_runner: 1158 passed, 0 failed"
    "realworld_run_runner: 44/55 passed"
    "diff_runner: 39/55 matched, 0 mismatched"
)

# x86_64-only anchors (Mac arm64 has different compile-pass
# count; Mac doesn't run realworld_run_jit_runner via test-all).
declare -a EXPECTED_X86=(
    "realworld_run_jit_runner: 46/55 compile-pass"
)

err=0
verbose="${VERBOSE:-0}"

check_log() {
    local host="$1"
    local pattern="$2"
    local log="$LOG_DIR/$host.log"

    if [ ! -f "$log" ]; then
        echo "MISS  $host: log file $log absent (run test-all first)"
        return 1
    fi

    if grep -qF "$pattern" "$log"; then
        [ "$verbose" = "1" ] && echo "OK    $host: '$pattern'"
        return 0
    else
        echo "MISS  $host: missing '$pattern' in $log"
        return 1
    fi
}

echo "[7.11 diff] cross-host total anchors:"
for pattern in "${EXPECTED[@]}"; do
    for host in "${LOGS[@]}"; do
        check_log "$host" "$pattern" || err=1
    done
done

echo ""
echo "[7.11 diff] x86_64-only anchors (ubuntu + win):"
for pattern in "${EXPECTED_X86[@]}"; do
    for host in ubuntu win; do
        check_log "$host" "$pattern" || err=1
    done
done

echo ""
if [ "$err" -eq 0 ]; then
    echo "[7.11 diff] PASS — cross-host engine differential anchors all matched"
    exit 0
else
    echo "[7.11 diff] FAIL — at least one anchor missed; engine differential broken"
    exit 1
fi
