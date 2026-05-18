#!/usr/bin/env bash
# scripts/check_subrow_exit.sh — Chunk-close literal exit gate (skeleton).
#
# pre-push hook: when a commit contains a `[x]` flip for a ROADMAP §9.12-X
# sub-row, verify the exit criteria are literally satisfied.
#
# Examples:
#   - §9.12-E close commit → verify skip-impl == 0 (= run
#     `zig build test-spec-wasm-2.0-assert` + grep result)
#   - §9.12-B close commit → verify build-completeness E2E green (= run
#     `zig build test-build-completeness`)
#   - §9.12-A close commit → verify all 9 enforcement items are wired
#     into gate_commit / pre-push
#
# Phase 9 completion master plan §7.6.
#
# Status: skeleton (2026-05-19) — completed in §9.12-A. Currently exits 0
# with usage hint.

set -uo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  sed -n '2,18p' "$0"
  exit 0
fi

echo "[check_subrow_exit] skeleton — TODO(§9.12-A): implement per-sub-row exit checks"
echo "[check_subrow_exit] expected behaviour:"
echo "  1. Parse staged ROADMAP diff for §9.12-X [x] flip markers"
echo "  2. For each flipped sub-row, run its registered exit gate:"
echo "     §9.12-E → skip-impl == 0 check"
echo "     §9.12-B → 6 build-option combination test pass"
echo "     §9.12-A → enforcement-9-item wiring verification"
echo "     ... (see phase9_completion_master_plan.md §5.3)"
echo "  3. FAIL with the failing sub-row name + missing exit criterion"
echo ""
echo "[check_subrow_exit] (skeleton; exit 0)"
exit 0
