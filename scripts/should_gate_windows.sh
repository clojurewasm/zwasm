#!/usr/bin/env bash
# DEPRECATED (2026-07-03) — local windowsmini gating is no longer load-bearing.
#
# CI's `ci-required` status check now runs the Windows leg on EVERY PR (the
# 3-OS gate), so per-PR Windows coverage for merge safety is CI's job. The old
# BATCHED/suspend heuristic (≥6/≥12-commit batching, ABI-path detection, and
# the `.dev/windows_gate_suspended` sentinel with --suspend/--resume) is retired
# and has been removed — that machinery only made sense while the autonomous
# loop batched local windowsmini runs. Any `.dev/windows_gate_suspended`
# sentinel left on disk is now OBSOLETE (ignored; safe to delete).
#
# A local Windows run remains OPTIONAL as a pre-PR pre-flight. If you want one,
# run `scripts/run_remote_windows.sh test-all` directly (SSH to windowsmini).
#
# This stub always exits 0; it no longer decides anything.

set -euo pipefail
cd "$(dirname "$0")/.."

echo "[should_gate_windows] DEPRECATED — per-PR Windows coverage is now CI's job"
echo "[should_gate_windows]   (ci-required 3-OS gate runs the Windows leg on every PR)."
if [ -f scripts/run_remote_windows.sh ]; then
    echo "[should_gate_windows] Optional local pre-flight: bash scripts/run_remote_windows.sh test-all"
fi
exit 0
