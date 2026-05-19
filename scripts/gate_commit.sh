#!/usr/bin/env bash
# Pre-commit gate. Runs (in order):
#   1. Diff classification (docs-only / src-touching / ADR-touching) — drives short-circuits.
#   2. zig fmt --check src/                                 — always.
#   3. scripts/zone_check.sh --gate                          — skipped on docs-only.
#   4. scripts/file_size_check.sh --gate                    — skipped on docs-only.
#   5. scripts/check_skip_adrs.sh --gate                     — skipped on docs-only.
#   6. scripts/check_adr_history.sh --gate                   — only when an ADR changed.
#   7. scripts/check_lesson_citing.sh                        — info only (warn count).
#   8. scripts/check_libc_boundary.sh (report)              — info; skipped on docs-only.
#   9. scripts/check_fallback_patterns.sh (report)          — info; skipped on docs-only.
#  10. zig build test (Mac native)                          — skipped on docs-only.
#
# Per the A6 gate consolidation study (§9.12-A / A6), docs/config-only
# diffs cannot move src/-related gate outcomes, so they short-circuit.
# Target: ~29 s docs-only pre-commit → ~3 s.
#
# Conservative case (ANY_STAGED=0, i.e. `git commit -a` / amend with
# empty --cached): treated as src-touching to be safe.
#
# Exits non-zero on any gate failure.

set -euo pipefail
cd "$(dirname "$0")/.."

# --- diff classification -------------------------------------------------

STAGED="$(git diff --cached --name-only)"
SRC_TOUCHED=0
ADR_TOUCHED=0
ANY_STAGED=0
if [ -n "$STAGED" ]; then
    ANY_STAGED=1
    while IFS= read -r f; do
        case "$f" in
            src/*|test/*|include/*|build.zig|build.zig.zon|flake.nix|flake.lock)
                SRC_TOUCHED=1
                ;;
            .dev/decisions/*.md|.dev/decisions/*/*.md)
                ADR_TOUCHED=1
                ;;
        esac
    done <<< "$STAGED"
fi

DOCS_ONLY=0
if [ "$ANY_STAGED" -eq 1 ] && [ "$SRC_TOUCHED" -eq 0 ] && [ "$ADR_TOUCHED" -eq 0 ]; then
    DOCS_ONLY=1
fi

# --- gate: zig fmt (always) ---------------------------------------------

echo "[gate_commit] zig fmt --check src/ ..."
if [ -d src ] && [ -n "$(find src -name '*.zig' 2>/dev/null | head -1)" ]; then
    zig fmt --check src/
else
    echo "(no src/*.zig yet — skipping fmt)"
fi

# --- gates: zone + file_size + skip_adrs (skipped on docs-only) ---------

if [ "$DOCS_ONLY" -eq 1 ]; then
    echo "[gate_commit] (docs-only diff — skipping zone_check + file_size_check + check_skip_adrs)"
else
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
fi

# --- gate: check_adr_history (only when an ADR changed or empty diff) ---

if [ "$ADR_TOUCHED" -eq 1 ] || [ "$ANY_STAGED" -eq 0 ]; then
    if [ -x scripts/check_adr_history.sh ]; then
        echo "[gate_commit] check_adr_history --gate ..."
        bash scripts/check_adr_history.sh --gate > /dev/null
    fi
elif [ "$DOCS_ONLY" -eq 0 ]; then
    echo "[gate_commit] (no ADR changed — skipping check_adr_history)"
fi

# --- gate: lesson citing (info only) ------------------------------------

if [ -x scripts/check_lesson_citing.sh ]; then
    n=$(bash scripts/check_lesson_citing.sh 2>&1 | grep -c '^WARN ') || true
    if [ "$n" -gt 0 ]; then
        echo "[gate_commit] (info) $n lesson(s) with unfilled Citing — backfill at phase boundary"
    fi
fi

# --- gates: A1 checks (informational; skipped on docs-only) -------------
#
# Per §9.12-A / A7: wire as informational, not --gate, until the
# precondition cleanups land:
#   - check_libc_boundary --gate fails on 9 replaceable sites cleared
#     in §9.12-D sample migration.
#   - check_fallback_patterns --gate fails on 10 existing `catch {}`
#     sites cleared in a follow-up (each marked EXEMPT-FALLBACK OR
#     rewritten to propagate the error).
# When those preconditions clear, swap each invocation to --gate mode.

if [ "$DOCS_ONLY" -eq 0 ]; then
    if [ -x scripts/check_libc_boundary.sh ]; then
        n=$(bash scripts/check_libc_boundary.sh 2>&1 | awk '/^replaceable:/{print $2; exit}')
        if [ -n "${n:-}" ] && [ "$n" != "0" ]; then
            echo "[gate_commit] (info) check_libc_boundary: $n replaceable site(s) — migration in §9.12-D"
        fi
    fi
    if [ -x scripts/check_fallback_patterns.sh ]; then
        n=$(bash scripts/check_fallback_patterns.sh 2>&1 | awk '/^fail:/{print $2; exit}')
        if [ -n "${n:-}" ] && [ "$n" != "0" ]; then
            echo "[gate_commit] (info) check_fallback_patterns: $n fail site(s) — cleanup in §9.12-A follow-up"
        fi
    fi
fi

# --- gate: zig build test (skipped on docs-only) ------------------------

if [ ! -f build.zig ]; then
    echo "[gate_commit] (no build.zig — skipping zig build test)"
elif [ "$DOCS_ONLY" -eq 1 ]; then
    echo "[gate_commit] (docs/config-only diff — skipping zig build test)"
else
    echo "[gate_commit] zig build test ..."
    zig build test
fi

echo "[gate_commit] All gates passed."
