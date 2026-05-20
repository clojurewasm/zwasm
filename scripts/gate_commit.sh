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
#  10. scripts/check_invariant_comments.sh --strict         — gate (ADR-0077, B128); skipped on docs-only.
#  11. zig build test (Mac native)                          — skipped on docs-only.
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

# --- arg parsing ---------------------------------------------------------
#
# --fast: skip `zig build test` and `zig build lint`. Used by the
# pre-commit / pre-push hooks (ADR-0076 D4): the /continue loop is
# already responsible for running test (Step 5) + lint (Step 4) before
# commit, and re-running them inside the git hook is pure duplication.
# Manual commits OR explicit `bash scripts/gate_commit.sh` (no flag)
# still run the full gate as a safety net.

FAST_MODE=0
for arg in "$@"; do
    case "$arg" in
        --fast) FAST_MODE=1 ;;
    esac
done

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
    # zone_check.sh walks every `src/**/*.zig` file with a per-file
    # awk + grep + cd subshell, costing ~100 s in current shape.
    # In --fast mode it is delegated to `audit_scaffolding` (periodic)
    # — the rule itself is load-bearing, but per-commit enforcement
    # at this cost is not. Full-gate mode (no --fast) still runs it
    # as a manual-commit safety net (per ADR-0076 D4 amend).
    if [ "$FAST_MODE" -eq 1 ]; then
        echo "[gate_commit] (--fast — skipping zone_check; audit_scaffolding owns it per ADR-0076 D4)"
    else
        echo "[gate_commit] zone_check --gate ..."
        bash scripts/zone_check.sh --gate
    fi

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
    # NOTE: `awk '... exit'` would SIGPIPE the upstream pipe, which with
    # `set -o pipefail` aborts gate_commit.sh. Use `grep | head` instead
    # (head reads exactly one line; the pipe closes cleanly).
    if [ -x scripts/check_libc_boundary.sh ]; then
        n=$(bash scripts/check_libc_boundary.sh 2>&1 | grep -E '^replaceable:' | head -1 | awk '{print $2}') || true
        if [ -n "${n:-}" ] && [ "$n" != "0" ]; then
            echo "[gate_commit] (info) check_libc_boundary: $n replaceable site(s) — migration in §9.12-D"
        fi
    fi
    if [ -x scripts/check_fallback_patterns.sh ]; then
        n=$(bash scripts/check_fallback_patterns.sh 2>&1 | grep -E '^fail:' | head -1 | awk '{print $2}') || true
        if [ -n "${n:-}" ] && [ "$n" != "0" ]; then
            echo "[gate_commit] (info) check_fallback_patterns: $n fail site(s) — cleanup in §9.12-A follow-up"
        fi
    fi
    # ADR-0077 strict gate (§9.12-C / B128). The B126 sweep
    # discharged all 55 latent overlap sites; --strict now fails
    # on any new digit-literal in the arm64 op_*.zig pool range,
    # forbidding re-introduction of the D-132/D-133 failure mode.
    if [ -x scripts/check_invariant_comments.sh ]; then
        echo "[gate_commit] check_invariant_comments --strict ..."
        bash scripts/check_invariant_comments.sh --strict > /dev/null
    fi
fi

# --- gate: zig build test (skipped on docs-only OR --fast) ---------------

if [ "$FAST_MODE" -eq 1 ]; then
    echo "[gate_commit] (--fast — skipping zig build test; /continue Step 5 owns it per ADR-0076 D4)"
elif [ ! -f build.zig ]; then
    echo "[gate_commit] (no build.zig — skipping zig build test)"
elif [ "$DOCS_ONLY" -eq 1 ]; then
    echo "[gate_commit] (docs/config-only diff — skipping zig build test)"
else
    echo "[gate_commit] zig build test ..."
    zig build test
fi

# --- gate: zig build lint (skipped on docs-only OR --fast) ---------------
#
# Lint findings are platform-independent and architecturally orthogonal
# to test failures, so they get their own gate. In --fast mode the
# /continue Step 4 owns it (per ADR-0076 D4).

if [ "$FAST_MODE" -eq 1 ]; then
    echo "[gate_commit] (--fast — skipping zig build lint; /continue Step 4 owns it per ADR-0076 D4)"
elif [ ! -f build.zig ]; then
    echo "[gate_commit] (no build.zig — skipping zig build lint)"
elif [ "$DOCS_ONLY" -eq 1 ]; then
    echo "[gate_commit] (docs/config-only diff — skipping zig build lint)"
else
    echo "[gate_commit] zig build lint ..."
    zig build lint -- --max-warnings 0
fi

echo "[gate_commit] All gates passed."
