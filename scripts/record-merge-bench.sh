#!/usr/bin/env bash
# scripts/record-merge-bench.sh — append a benchmark row to
# bench/history.yaml for the current commit.
#
# Project policy: every merge to main gets one row per platform the
# user has access to. Run this after the PR is merged and main is
# checked out locally, NOT before — the row should reference the
# merge commit, not the branch tip.
#
# Multi-arch (C-g, 2026-04-29): bench/history.yaml stores entries for
# every target triple side by side; each row carries `arch:`
# (auto-detected from `uname -s -m`, override with --arch=...). Mac
# aarch64-darwin remains the canonical absolute-time baseline used at
# tag time, but x86_64-linux and x86_64-windows rows are encouraged
# so that cross-platform regressions surface early.
#
# Usage:
#   bash scripts/record-merge-bench.sh                       # full record (5 runs + 3 warmup)
#   bash scripts/record-merge-bench.sh --reason="..."        # override default reason
#   bash scripts/record-merge-bench.sh --arch=x86_64-linux   # explicit triple
#
# All arguments after the script are passed straight to
# bench/record.sh. --id, --reason, and --arch are auto-filled when
# the caller does not pass them explicitly.
#
# Always use the default 5 runs + 3 warmup. bench/history.yaml is the
# canonical absolute-time baseline used at tag time; lower run/warmup
# counts produce noisy / cold-cache-biased numbers that distort the
# long-term trend graph. `bench/run_bench.sh --quick` exists for
# interactive smoke tests — use that, not record.sh, when you just
# want a fast local check.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/versions.sh
source "$SCRIPT_DIR/lib/versions.sh"

cd "$ZWASM_REPO_ROOT"

# Allow caller to override --id / --reason / --arch. We default-fill
# them from git / `uname` only when the caller did not pass them.
have_id=false
have_reason=false
have_arch=false
for arg in "$@"; do
    case "$arg" in
        --id=*)     have_id=true ;;
        --reason=*) have_reason=true ;;
        --arch=*)   have_arch=true ;;
    esac
done

extra_args=()
if ! $have_id; then
    extra_args+=("--id=$(git rev-parse --short HEAD)")
fi
if ! $have_reason; then
    extra_args+=("--reason=$(git log -1 --pretty=%s)")
fi
if ! $have_arch; then
    case "$(uname -s)-$(uname -m)" in
        Darwin-arm64)        extra_args+=("--arch=aarch64-darwin") ;;
        Darwin-x86_64)       extra_args+=("--arch=x86_64-darwin") ;;
        Linux-x86_64)        extra_args+=("--arch=x86_64-linux") ;;
        Linux-aarch64)       extra_args+=("--arch=aarch64-linux") ;;
        MINGW*-x86_64|MSYS*-x86_64|CYGWIN*-x86_64) extra_args+=("--arch=x86_64-windows") ;;
        *)
            echo "record-merge-bench: cannot auto-detect target triple ($(uname -s)/$(uname -m))." >&2
            echo "                    Pass --arch=<triple> explicitly." >&2
            exit 1
            ;;
    esac
fi

# Idempotent: if the auto-derived id already exists, the inner
# bench/record.sh will refuse without --overwrite. That's intentional
# — re-recording the same SHA usually means the user already ran this
# once. Surface the conflict rather than silently re-measuring.
exec bash bench/record.sh "${extra_args[@]}" "$@"
