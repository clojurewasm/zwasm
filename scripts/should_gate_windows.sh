#!/usr/bin/env bash
# Decide whether the current /continue chunk needs a windowsmini
# gate run, or can defer to the next checkpoint.
#
# Background: the autonomous loop's per-chunk 3-host gate (Mac +
# OrbStack + windowsmini) was empirically over-gating for the
# §9.7 / §9.9 chunk shapes (encoder + handler additions). Across
# the ~15 chunks in the 9.7-at..9.9-b run, windowsmini surfaced
# zero unique findings vs Mac + OrbStack but added ~2-3 min wall-
# clock per chunk, dominating cycle time. See lesson
# `.dev/lessons/2026-05-10-loop-overgating-retro.md`.
#
# This script's heuristic: run windowsmini when the diff plausibly
# triggers Win64-specific code paths (ABI / calling convention /
# frame layout), OR after 4+ commits without a windowsmini run.
# Otherwise defer.
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
COMMIT_COUNT=$(git rev-list --count "${LAST}..HEAD" 2>/dev/null || echo 999)

DIFF_FILES=$(git diff --name-only "${LAST}..HEAD" 2>/dev/null || echo '')

# Trigger 1: ABI-touching path.
for path in "${ABI_PATHS[@]}"; do
    if echo "$DIFF_FILES" | grep -qF "$path"; then
        echo "gate-required: ABI-touching path '$path' modified since $LAST"
        exit 0
    fi
done

# Trigger 2: emit.zig param/return marshal area (lines 1-300
# carry the param-decode + uses_runtime_ptr prescan + frame
# sizing; lines 1450-1550 carry the return marshal). These are
# Win64-vs-SysV divergence surfaces.
if echo "$DIFF_FILES" | grep -qF 'src/engine/codegen/x86_64/emit.zig'; then
    if git diff -U0 "${LAST}..HEAD" -- src/engine/codegen/x86_64/emit.zig 2>/dev/null | grep -qE '^@@ .*\+([1-9][0-9]?|[12][0-9]{2}|300|14[5-9][0-9]|15[0-5][0-9]),'; then
        echo "gate-required: emit.zig param/return marshal area touched"
        exit 0
    fi
fi

# Trigger 3: 4+ commits since last windowsmini run. Caps the
# unbounded drift risk for chunk-shape changes that don't hit
# the explicit ABI paths.
if [ "$COMMIT_COUNT" -ge 4 ]; then
    echo "gate-required: $COMMIT_COUNT commits since last windowsmini run"
    exit 0
fi

echo "gate-deferred: $COMMIT_COUNT commit(s) since $LAST, no ABI-touching paths in diff"
exit 1
