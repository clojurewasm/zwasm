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

# Per ADR-0029 Path B (chunk 9.9-h-24): verify prefix-vocab
# coherence — every `skip-adr-<id>` manifest line resolves to an
# existing `.dev/decisions/skip_<id>.md` ADR, and every skip-ADR
# has ≥ 1 manifest consumer (no orphans). Plus the original
# fixture-path existence checks for cited `.wasm` files.
echo "[gate_commit] check_skip_adrs --gate ..."
bash scripts/check_skip_adrs.sh --gate > /dev/null

# Lesson Citing-backfill awareness (warn-only; per
# `.claude/rules/lessons_vs_adr.md` Citing-header discipline).
# The audit_scaffolding §F.3a check is the authoritative version;
# this is the cheap per-commit visibility hook.
if [ -x scripts/check_lesson_citing.sh ]; then
    n=$(bash scripts/check_lesson_citing.sh 2>&1 | grep -c '^WARN ') || true
    if [ "$n" -gt 0 ]; then
        echo "[gate_commit] (info) $n lesson(s) with unfilled Citing — backfill at phase boundary"
    fi
fi

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
