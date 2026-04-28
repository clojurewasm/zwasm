#!/usr/bin/env bash
# scripts/gate-merge.sh — Merge Gate runner.
#
# Mirrors `### Merge Gate Checklist` in CLAUDE.md. Adds three checks
# on top of gate-commit.sh:
#
#   - bench  — quick benchmark sanity (full run takes too long here;
#              regression checking is CI's job via bench/ci_compare.sh)
#   - sync   — versions.lock ↔ flake.nix consistency (item #9)
#   - ci     — main-branch CI green check (item #8). Skipped locally
#              when not on main; intended for the post-push manual run.
#
# Per CLAUDE.md the Merge Gate must pass on BOTH macOS AND Ubuntu
# x86_64. This script handles one host at a time; run it once on each
# host (Mac directly, Ubuntu via OrbStack) before merging.
#
# Usage:
#   bash scripts/gate-merge.sh                  # full Merge Gate
#   bash scripts/gate-merge.sh --skip=bench     # skip bench locally
#   bash scripts/gate-merge.sh --skip-ci-check  # skip the gh CI lookup
#
# Exit codes: 0 all green, 1 first failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/versions.sh
source "$SCRIPT_DIR/lib/versions.sh"

cd "$ZWASM_REPO_ROOT"

# --- Argument parsing ---

SKIP_LIST=""
SKIP_CI_CHECK=0
for arg in "$@"; do
    case "$arg" in
        --skip=*) SKIP_LIST="$SKIP_LIST ${arg#--skip=}" ;;
        --skip-ci-check) SKIP_CI_CHECK=1 ;;
        --help|-h)
            sed -n '2,22p' "$0"
            exit 0
            ;;
        *)
            echo "gate-merge: unknown argument: $arg" >&2
            exit 2
            ;;
    esac
done

# --- Run Commit Gate first (items 1-6 + minimal) ---

echo "=== Running Commit Gate ==="
if ! bash "$SCRIPT_DIR/gate-commit.sh" --bench; then
    echo "gate-merge: Commit Gate failed; not proceeding to Merge-Gate-only checks." >&2
    exit 1
fi

# --- Merge-Gate-only steps ---

STEPS_RUN=0
STEPS_PASSED=0
STEPS_FAILED=0
FAILED_NAMES=""

should_run() {
    case " $SKIP_LIST " in
        *" $1 "*) return 1 ;;
    esac
    return 0
}

run_step() {
    local name="$1"
    shift
    if ! should_run "$name"; then
        printf '  [SKIP] %s\n' "$name"
        return 0
    fi
    STEPS_RUN=$((STEPS_RUN + 1))
    printf '\n=== [%s] %s ===\n' "$name" "$*"
    if "$@"; then
        STEPS_PASSED=$((STEPS_PASSED + 1))
        printf '  [PASS] %s\n' "$name"
    else
        STEPS_FAILED=$((STEPS_FAILED + 1))
        FAILED_NAMES="$FAILED_NAMES $name"
        printf '  [FAIL] %s\n' "$name"
    fi
}

step_sync_versions() {
    bash "$SCRIPT_DIR/sync-versions.sh"
}

step_ci_check() {
    if [ "$SKIP_CI_CHECK" -eq 1 ]; then
        echo "  ci-check skipped via --skip-ci-check"
        return 0
    fi
    if ! command -v gh >/dev/null 2>&1; then
        echo "  gh CLI not available; skipping main-branch CI check" >&2
        return 0
    fi
    local conclusion
    conclusion="$(gh run list --branch main --limit 1 \
        --json conclusion --jq '.[0].conclusion' 2>/dev/null || echo "")"
    case "$conclusion" in
        success) echo "  main CI: success"; return 0 ;;
        ""|null) echo "  main CI: no run found (acceptable)"; return 0 ;;
        *)       echo "  main CI: $conclusion"; return 1 ;;
    esac
}

run_step sync     step_sync_versions
run_step ci       step_ci_check

# --- Summary ---

echo
echo "=== Merge Gate summary ==="
printf '  merge-gate-only-steps: ran=%d passed=%d failed=%d\n' \
    "$STEPS_RUN" "$STEPS_PASSED" "$STEPS_FAILED"
if [ "$STEPS_FAILED" -gt 0 ]; then
    printf '  failed steps:%s\n' "$FAILED_NAMES"
    echo "Reminder: Merge Gate also requires Ubuntu x86_64 verification (OrbStack)." >&2
    exit 1
fi
echo "Reminder: Merge Gate also requires Ubuntu x86_64 verification (OrbStack)."
exit 0
