#!/usr/bin/env bash
# Decide whether the current /continue chunk needs a windowsmini
# gate run, or can defer to the next checkpoint.
#
# Background: the autonomous loop's per-chunk 3-host gate (Mac +
# Linux x86_64 + windowsmini) was empirically over-gating for the
# §9.7 / §9.9 chunk shapes (encoder + handler additions). Across
# the ~15 chunks in the 9.7-at..9.9-b run, windowsmini surfaced
# zero unique findings vs Mac + Linux but added ~2-3 min wall-
# clock per chunk, dominating cycle time. See lesson
# `.dev/lessons/2026-05-10-loop-overgating-retro.md`.
#
# Post-ADR-0067: Linux x86_64 host is now ubuntunote (native);
# OrbStack retired from gate per D-134 Rosetta closure. This
# heuristic's logic is unchanged.
#
# This script's heuristic (ADR-0076 D8, user-directed 2026-06-06 —
# BATCHED cadence for faster iteration): run windowsmini once per
# BATCH — after 6 commits if the batch touched ABI/calling-convention/
# frame-layout paths, else after 12 commits. ABI-risk is no longer an
# immediate per-commit trigger (it just lowers the batch size). Keep
# chaining chunks on Mac+ubuntu meanwhile; never poll-wait on windows.
#
# Exit codes:
#   0 — gate required (run windowsmini this chunk)
#   1 — gate deferred (skip windowsmini; next checkpoint will catch it)
#
# Modes:
#   should_gate_windows.sh           → decide; print rationale
#   should_gate_windows.sh --record  → update .dev/last_windowsmini_sha to HEAD
#                                      (call after a successful windowsmini run)

set -euo pipefail
cd "$(dirname "$0")/.."

LAST_FILE='.dev/last_windowsmini_sha'

if [ "${1:-}" = '--record' ]; then
    git rev-parse HEAD > "$LAST_FILE"
    echo "[should_gate_windows] recorded HEAD = $(git rev-parse --short HEAD) as last windowsmini-tested commit"
    exit 0
fi

# ABI / calling-convention / frame-layout file paths. Diff hitting
# any of these → run windowsmini this chunk (Win64 vs SysV ABI
# divergence may surface).
ABI_PATHS=(
    'src/engine/codegen/x86_64/abi.zig'
    'src/engine/codegen/x86_64/op_call.zig'
    'src/engine/codegen/shared/jit_abi.zig'
    'src/engine/codegen/shared/entry.zig'
    'src/engine/codegen/x86_64/prologue.zig'
    'build.zig'
    'scripts/run_remote_windows.sh'
)

if [ -f "$LAST_FILE" ]; then
    LAST=$(cat "$LAST_FILE")
    # Validate the recorded SHA still exists (not amended-away).
    if ! git rev-parse --verify "$LAST^{commit}" >/dev/null 2>&1; then
        LAST='HEAD~10'
    fi
else
    # First run: be conservative — gate.
    echo "gate-required: no $LAST_FILE record yet (first run)"
    exit 0
fi

# How many commits ahead of the last windowsmini-tested SHA?
# `|| echo 999` is fail-safe (over-gates rather than under-gates)
# but masks the underlying error. Capture stderr to a temp so a
# real `git rev-list` failure (missing ref / corrupt object DB)
# surfaces on stderr while still defaulting to gate-required.
gitrev_err=$(mktemp)
if COMMIT_COUNT=$(git rev-list --count "${LAST}..HEAD" 2>"$gitrev_err"); then
    :
else
    COMMIT_COUNT=999
    echo "WARN: git rev-list --count ${LAST}..HEAD failed (likely missing ref); defaulting to gate-required." >&2
    cat "$gitrev_err" >&2
fi
rm -f "$gitrev_err"

DIFF_FILES=$(git diff --name-only "${LAST}..HEAD" 2>/dev/null || echo '')

# Cadence model (ADR-0076 D8, user-directed 2026-06-06): windows runs
# are BATCHED to keep iteration fast on Mac+ubuntu. Windows is the slow
# host; the loop chains MANY chunks per turn and runs windowsmini once
# per BATCH — NOT immediately per ABI-risk turn (the pre-D8 behavior,
# which made the loop poll-wait on windows too often). ABI-risk in the
# batch lowers the threshold (more responsive to Win64-divergence-prone
# diffs) but is no longer an immediate trigger. Heisenbug-awareness +
# Step 0.7 verdict verification unchanged. Thresholds:
#   - ABI-risk present in batch → 6 commits
#   - pure non-ABI batch        → 12 commits
ABI_THRESHOLD=6
NONABI_THRESHOLD=12

abi_risk=0
abi_reason=''
for path in "${ABI_PATHS[@]}"; do
    if echo "$DIFF_FILES" | grep -qF "$path"; then
        abi_risk=1
        abi_reason="ABI-touching path '$path'"
        break
    fi
done

# emit.zig param/return marshal area (lines 1-300: param-decode +
# uses_runtime_ptr prescan + frame sizing; 1450-1550: return marshal) —
# Win64-vs-SysV divergence surfaces; counts as ABI-risk for the threshold.
if [ "$abi_risk" -eq 0 ] && echo "$DIFF_FILES" | grep -qF 'src/engine/codegen/x86_64/emit.zig'; then
    if git diff -U0 "${LAST}..HEAD" -- src/engine/codegen/x86_64/emit.zig 2>/dev/null | grep -qE '^@@ .*\+([1-9][0-9]?|[12][0-9]{2}|300|14[5-9][0-9]|15[0-5][0-9]),'; then
        abi_risk=1
        abi_reason="emit.zig param/return marshal area"
    fi
fi

if [ "$abi_risk" -eq 1 ]; then
    THRESHOLD="$ABI_THRESHOLD"
else
    THRESHOLD="$NONABI_THRESHOLD"
fi

if [ "$COMMIT_COUNT" -ge "$THRESHOLD" ]; then
    if [ "$abi_risk" -eq 1 ]; then
        echo "gate-required: $COMMIT_COUNT commits ≥ ABI-risk batch threshold $THRESHOLD ($abi_reason) since $LAST"
    else
        echo "gate-required: $COMMIT_COUNT commits ≥ non-ABI batch threshold $THRESHOLD since $LAST"
    fi
    exit 0
fi

echo "gate-deferred: $COMMIT_COUNT/$THRESHOLD commits since $LAST (abi_risk=$abi_risk) — keep batching on Mac+ubuntu"
exit 1
