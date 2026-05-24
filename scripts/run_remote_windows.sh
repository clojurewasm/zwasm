#!/usr/bin/env bash
# scripts/run_remote_windows.sh — drive build/test on the windowsmini SSH host.
#
# `git fetch + reset --hard` the windowsmini clone to the latest
# pushed `origin/zwasm-from-scratch`, then run the requested
# `zig build` step there. Phase 15+ may extend this with a
# `git bundle` path so unpushed commits can also be exercised; for
# now we test the latest pushed state, mirroring zwasm v1.
#
# Usage:
#   bash scripts/run_remote_windows.sh                         # default: zig build test-all on zwasm-from-scratch
#   bash scripts/run_remote_windows.sh build                   # zig build
#   bash scripts/run_remote_windows.sh test                    # zig build test
#   bash scripts/run_remote_windows.sh test-spec               # zig build test-spec
#   bash scripts/run_remote_windows.sh --branch NAME [STEP]    # test arbitrary branch (feature-branch verification)
#
# The `--branch` form mirrors run_remote_ubuntu.sh and is used
# by §9.13-V Phase A.6 to verify feature branches (e.g.
# `zwasm-from-scratch-value16`) before merging to the main dev
# branch.
#
# Prerequisites: SSH alias `windowsmini` configured; Zig 0.16.0
# installed remotely; the repo cloned at
# ~/Documents/MyProducts/zwasm_from_scratch (see
# `.dev/windows_ssh_setup.md`).

set -euo pipefail
cd "$(dirname "$0")/.."

REMOTE_DIR="Documents/MyProducts/zwasm_from_scratch"
REMOTE_BRANCH="zwasm-from-scratch"
if [ "${1:-}" = "--branch" ]; then
    if [ -z "${2:-}" ]; then
        echo "[run_remote_windows] FAIL: --branch requires a branch name" >&2
        exit 2
    fi
    REMOTE_BRANCH="$2"
    shift 2
fi
STEP="${1:-test-all}"

echo "[run_remote_windows] sync windowsmini:~/$REMOTE_DIR to origin/$REMOTE_BRANCH ..."
ssh windowsmini bash -lc "'cd $REMOTE_DIR && git fetch origin $REMOTE_BRANCH && git checkout $REMOTE_BRANCH && git reset --hard origin/$REMOTE_BRANCH'"

# `build` is the implicit (default) step in build.zig — invoking
# `zig build build` errors. Map the human-friendly arg to no step.
if [ "$STEP" = "build" ]; then
    REMOTE_CMD="zig build"
else
    REMOTE_CMD="zig build $STEP"
fi

echo "[run_remote_windows] $REMOTE_CMD ..."
ssh windowsmini bash -lc "'cd $REMOTE_DIR && $REMOTE_CMD'"

echo "[run_remote_windows] OK."
