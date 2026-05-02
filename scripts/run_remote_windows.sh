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
#   bash scripts/run_remote_windows.sh                  # default: zig build test-all
#   bash scripts/run_remote_windows.sh build            # zig build
#   bash scripts/run_remote_windows.sh test             # zig build test
#   bash scripts/run_remote_windows.sh test-spec        # zig build test-spec
#
# Prerequisites: SSH alias `windowsmini` configured; Zig 0.16.0
# installed remotely; the repo cloned at
# ~/Documents/MyProducts/zwasm_from_scratch with `origin` pointing
# at clojurewasm/zwasm and the `zwasm-from-scratch` branch checked
# out (see .dev/windows_ssh_setup.md).

set -euo pipefail
cd "$(dirname "$0")/.."

STEP="${1:-test-all}"
REMOTE_DIR="Documents/MyProducts/zwasm_from_scratch"
REMOTE_BRANCH="zwasm-from-scratch"

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
