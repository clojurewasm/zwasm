#!/usr/bin/env bash
# scripts/run_remote_windows.sh — drive build/test on the windowsmini SSH host.
#
# rsync the repo to windowsmini, run the requested zig build step
# remotely, tee output back. Phase 14+ uses this in gate_merge.sh
# automatically; earlier phases call it on demand.
#
# Usage:
#   bash scripts/run_remote_windows.sh                  # default: zig build test-all
#   bash scripts/run_remote_windows.sh build            # zig build
#   bash scripts/run_remote_windows.sh test             # zig build test
#   bash scripts/run_remote_windows.sh test-spec        # zig build test-spec
#
# Prerequisites: SSH alias `windowsmini` configured; Zig 0.16.0
# installed remotely (.dev/windows_ssh_setup.md).

set -euo pipefail
cd "$(dirname "$0")/.."

STEP="${1:-test-all}"
REMOTE_DIR="zwasm_from_scratch"

echo "[run_remote_windows] rsync to windowsmini:~/$REMOTE_DIR/ ..."
rsync -a --delete \
    --exclude=.git --exclude=zig-out --exclude=.zig-cache \
    --exclude=private --exclude=test/spec/json --exclude=test/fuzz/corpus \
    ./ "windowsmini:~/$REMOTE_DIR/"

echo "[run_remote_windows] zig build $STEP ..."
ssh windowsmini "cd $REMOTE_DIR && zig build $STEP"

echo "[run_remote_windows] OK."
