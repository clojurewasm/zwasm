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
# Cadence (ROADMAP §12.4): the per-merge bench is MANUAL. Under PR-only `main`
# (ruleset-protected), record ON THE FEATURE BRANCH before opening the PR and
# commit `bench/results/history.yaml` INTO THE SAME PR — NOT as a post-merge
# follow-up (that would need its own PR each merge). Put the PR intent in
# `--reason`; the entry's commit SHA is the branch tip (cosmetic — reason/PR#/
# date identify it). Run on Mac; ubuntunote / windowsmini for Linux / Windows
# rows when needed. Auto-CI (push-triggered bench.yml) stays disabled
# (2026-05-25; CI was not consumed, auto-runs produced noise).
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
