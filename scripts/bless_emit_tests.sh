#!/usr/bin/env bash
# scripts/bless_emit_tests.sh — golden snapshot bless workflow
# entry point (10.T-4; Phase 10 design plan §4.7).
#
# Industry-standard env-var-gated bless: failing emit_test_*.zig
# expectations get auto-rewritten to the observed bytes when
# ZWASM_TEST_BLESS=1 is set. Without that env var, the runner
# treats mismatches as FAIL (no source mutation).
#
# Current status (10.T-4 skeleton):
# - 185 emit_test entries across arm64 + x86_64 (well past the
#   ~50-op manual-edit threshold cited in design plan §4.7)
# - Manual edit (`-Dprint-emit-bytes=1 zig build test`,
#   transcribe observed → expected by hand) remains acceptable
#   for the current Phase 10 baseline
# - Auto-bless impl is deferred to the cycle that first
#   accumulates ≥ 10 pending mismatches in a single chunk
#   (likely a SIMD-Phase-15-style cluster fix)
#
# The sidecar pattern from design plan §4.7 step 5 will land
# the impl when triggered:
#   - test runner detects ZWASM_TEST_BLESS=1
#   - mismatches append to `private/.bless-pending.txt` as
#     `<file>:<line> <observed-hex>`
#   - this script reads the sidecar + rewrites in place
#
# Usage (deferred):
#   ZWASM_TEST_BLESS=1 zig build test     # capture mismatches
#   bash scripts/bless_emit_tests.sh      # apply pending rewrites

set -euo pipefail
cd "$(dirname "$0")/.."

PENDING_FILE="private/.bless-pending.txt"

if [ ! -f "$PENDING_FILE" ]; then
    echo "[bless_emit_tests] no pending mismatches (impl deferred per design plan §4.7;"
    echo "  manual edit OK for ≤ 50-op clusters; sidecar capture activates when needed)"
    exit 0
fi

n=$(wc -l < "$PENDING_FILE" | tr -d ' ')
echo "[bless_emit_tests] ${n} pending mismatch(es) — auto-bless impl not yet landed"
echo "  Apply manually: read $PENDING_FILE entries and edit the cited emit_test_*.zig sites."
echo "  Auto-bless rewriter ships when first chunk accumulates ≥ 10 pending entries."
exit 0
