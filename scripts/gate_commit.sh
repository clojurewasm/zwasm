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

if [ ! -f build.zig ]; then
    echo "[gate_commit] (no build.zig — skipping zig build test)"
else
    # Skip the slow `zig build test` when staged changes touch only
    # docs / scaffolding / config — none of those can move the test
    # outcome. Source / build / test files force the full check.
    STAGED="$(git diff --cached --name-only)"
    NEEDS_TEST=0
    if [ -z "$STAGED" ]; then
        # `git commit -a`, amends, or other paths where --cached is
        # empty — play it safe.
        NEEDS_TEST=1
    else
        while IFS= read -r f; do
            case "$f" in
                src/*|test/*|include/*|build.zig|build.zig.zon|flake.nix|flake.lock)
                    NEEDS_TEST=1
                    break
                    ;;
            esac
        done <<< "$STAGED"
    fi

    if [ "$NEEDS_TEST" -eq 0 ]; then
        echo "[gate_commit] (docs/config-only diff — skipping zig build test)"
    else
        echo "[gate_commit] zig build test ..."
        zig build test
    fi
fi

echo "[gate_commit] All gates passed."
