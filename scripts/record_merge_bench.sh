#!/usr/bin/env bash
# Merge-time bench recorder — the §12.4 "per-merge (manual)" entry point
# for Phase 0-13. Thin wrapper over scripts/run_bench.sh, which is the real
# hyperfine engine (builds zwasm ReleaseSafe + runs bench/runners/*.wasm +
# the cljw_* guests, writing bench/results/recent.yaml).
#
# Without --phase-record: overwrites recent.yaml (gitignored, per-commit).
# With --phase-record: ALSO appends ONE entry to bench/results/history.yaml
# (committed, append-only) tagged with commit + arch + reason. Arch is
# auto-detected from `uname` ({aarch64-darwin, x86_64-linux, x86_64-windows}).
#
# Cadence (ROADMAP §12.4): during Phase 0-13 the per-merge bench is MANUAL —
# run this on Mac directly, and on ubuntunote / windowsmini for the Linux /
# Windows rows. Auto-CI (the push-triggered bench.yml) is Phase 14+; its
# push trigger was disabled 2026-05-25 per user direction (CI was not
# consumed; auto-runs produced noise). This script is the supported path
# until then.
#
# Usage:
#   bash scripts/record_merge_bench.sh                  # recent.yaml only
#   bash scripts/record_merge_bench.sh --quick          # quick (3 runs + 1 warmup)
#   bash scripts/record_merge_bench.sh --phase-record \
#        --reason='p11: <gist>'                         # append to history.yaml
#
# All flags forward verbatim to run_bench.sh (--quick / --phase-record /
# --reason= / --bench= / --compare= / --capture-rss / --windows-subset).
set -euo pipefail
cd "$(dirname "$0")/.."

exec bash scripts/run_bench.sh "$@"
