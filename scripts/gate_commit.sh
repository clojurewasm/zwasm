#!/usr/bin/env bash
# Pre-commit gate. Runs in order:
#   1. zig fmt --check src/
#   2. scripts/zone_check.sh --gate
#   3. scripts/file_size_check.sh --gate
#   4. zig build test (Mac native — full test-all is in pre-push)
#
# Exits non-zero on any gate failure.

set -euo pipefail
cd "$(dirname "$0")/.."

echo "[gate_commit] zig fmt --check src/ ..."
if [ -d src ] && [ -n "$(find src -name '*.zig' 2>/dev/null | head -1)" ]; then
    zig fmt --check src/
else
    echo "(no src/*.zig yet — skipping fmt)"
fi

echo "[gate_commit] zone_check --gate ..."
bash scripts/zone_check.sh --gate

echo "[gate_commit] file_size_check --gate ..."
bash scripts/file_size_check.sh --gate

echo "[gate_commit] zig build test ..."
if [ -f build.zig ]; then
    zig build test
else
    echo "(no build.zig — skipping)"
fi

echo "[gate_commit] All gates passed."
