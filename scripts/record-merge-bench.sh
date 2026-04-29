#!/usr/bin/env bash
# scripts/record-merge-bench.sh — append a benchmark row to
# bench/history.yaml for the current commit.
#
# Project policy: every merge to main gets one row. Run this after the
# PR is merged and main is checked out locally, NOT before — the row
# should reference the merge commit, not the branch tip.
#
# Mac-only by design. bench/history.yaml's env block declares
# `os: Darwin <version>` so cross-host entries would be misleading.
# On Linux/Windows the script logs and exits 0 so it can sit in a
# scripted post-merge flow without breaking it.
#
# Usage:
#   bash scripts/record-merge-bench.sh                 # full record (5 runs + 3 warmup)
#   bash scripts/record-merge-bench.sh --reason="..."  # override default reason
#
# All arguments after the script are passed straight to
# bench/record.sh. --id and --reason are auto-filled from the current
# HEAD commit if you do not pass them explicitly.
#
# Always use the default 5 runs + 3 warmup. bench/history.yaml is the
# canonical Mac M4 Pro absolute-time baseline used at tag time; lower
# run/warmup counts produce noisy / cold-cache-biased numbers that
# distort the long-term trend graph. `bench/run_bench.sh --quick`
# exists for interactive smoke tests — use that, not record.sh, when
# you just want a fast local check.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/versions.sh
source "$SCRIPT_DIR/lib/versions.sh"

cd "$ZWASM_REPO_ROOT"

if [ "$(uname)" != "Darwin" ]; then
    echo "record-merge-bench: bench/history.yaml is Mac-specific (env: Darwin)." >&2
    echo "                    Skipping on $(uname)." >&2
    exit 0
fi

# Allow caller to override --id / --reason. We default-fill them from
# git only when the caller did not pass either flag.
have_id=false
have_reason=false
for arg in "$@"; do
    case "$arg" in
        --id=*)     have_id=true ;;
        --reason=*) have_reason=true ;;
    esac
done

extra_args=()
if ! $have_id; then
    extra_args+=("--id=$(git rev-parse --short HEAD)")
fi
if ! $have_reason; then
    extra_args+=("--reason=$(git log -1 --pretty=%s)")
fi

# Idempotent: if the auto-derived id already exists, the inner
# bench/record.sh will refuse without --overwrite. That's intentional
# — re-recording the same SHA usually means the user already ran this
# once. Surface the conflict rather than silently re-measuring.
exec bash bench/record.sh "${extra_args[@]}" "$@"
