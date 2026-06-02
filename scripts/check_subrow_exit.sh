#!/usr/bin/env bash
# scripts/check_subrow_exit.sh — Chunk-close literal exit gate.
#
# DORMANT (2026-06-02): this only fires on a §9.12-X `[x]` flip in HEAD's diff;
# Phase 9 is DONE so it no longer triggers. It is NOT the live build-option DCE
# guard — check_9_12_B's one-shot `check_build_dce.sh --gate` ran only at §9.12-B
# close (when no 3.0 op was yet manually-dispatched in arm64/emit.zig). The
# Phase-10 EH/TC/funcref work added unguarded 3.0 prongs later with no re-run →
# the leak (ADR-0130 / D-230). CONTINUOUS DCE enforcement now lives in
# `gate_merge.sh` (every `main` push). Lesson: 2026-06-02-detection-without-enforcement-dead-gate.
#
# When HEAD's diff contains a `[x]` flip for a ROADMAP §9.12-X sub-row,
# run the registered exit check for that sub-row and FAIL if any literal
# criterion is unmet.
#
# Registered checks (per phase9_completion_master_plan.md §5.3):
#   §9.12-A  → 9 enforcement-layer items wired (scripts non-skeleton + dispatch_collector + rules)
#   §9.12-B  → 6 build-option combinations all pass test-all
#   §9.12-C  → audit §G invariant-comments returns 0; comment_as_invariant rule body landed
#   §9.12-D  → check_libc_boundary --gate exits 0
#   §9.12-E  → skip-impl == 0 (Mac + ubuntunote bit-identical via ratchet check)
#   §9.12-F  → debt active row count < 15
#   §9.12-G  → zone_check --gate returns 0
#   §9.12-H  → bench history.yaml has p9-close baseline row
#   §9.12-I  → check_adr_history --gate + check_lesson_citing return 0
#
# Phase 9 completion master plan §7.6.
#
# Modes:
#   --gate          : exit non-zero on any FAIL (pre-push hook)
#   --check <row>   : verify named sub-row even without git diff
#   --report        : exit 0; report all sub-rows' status

set -uo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  sed -n '2,24p' "$0"
  exit 0
fi

MODE="${1:-report}"
TARGET_ROW="${2:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# --- discover [x] flips in HEAD's diff -----------------------------------

discover_flipped_rows() {
  # Lines added in HEAD that look like `| 9.12-X | ... | [x] ...`.
  git diff HEAD~1..HEAD --unified=0 .dev/ROADMAP.md 2>/dev/null \
    | grep -E '^\+\|[[:space:]]*9\.1[23](-[A-Z0-9]+)?[[:space:]]' \
    | grep -E '\| \[x\] *' \
    | sed -E 's/^\+\|[[:space:]]*//; s/[[:space:]].*$//' \
    | sort -u
}

# --- per-sub-row checks --------------------------------------------------

check_9_12_A() {
  local fail=0 f n
  # p9_completion_status removed 2026-05-22 per ADR-0104 — §9.12-A
  # enforcement-artefact discipline replaced by invariant-script
  # approach (see .dev/phase9_close_master.md §4 Phase C).
  for s in check_build_dce check_skip_impl_ratchet check_fallback_patterns \
           check_subrow_exit check_libc_boundary; do
    f="scripts/$s.sh"
    if [ ! -x "$f" ]; then echo "  MISS  $f"; fail=1; continue; fi
    n=$(wc -l < "$f")
    if [ "$n" -lt 50 ]; then echo "  THIN  $f ($n lines)"; fail=1; continue; fi
    echo "  OK    $f ($n lines)"
  done
  if [ -f src/ir/dispatch_collector.zig ]; then
    echo "  OK    src/ir/dispatch_collector.zig"
  else
    echo "  MISS  src/ir/dispatch_collector.zig"
    fail=1
  fi
  for r in no_fallback_on_failure spike_lifecycle libc_boundary runtime_instance_layer; do
    f=".claude/rules/$r.md"
    if [ ! -f "$f" ]; then echo "  MISS  $f"; fail=1; continue; fi
    n=$(wc -l < "$f")
    if [ "$n" -lt 30 ]; then echo "  THIN  $f ($n lines)"; fail=1; continue; fi
    echo "  OK    $f ($n lines)"
  done
  if [ -f .claude/skills/dispatch_consistency_audit/SKILL.md ]; then
    n=$(wc -l < .claude/skills/dispatch_consistency_audit/SKILL.md)
    if [ "$n" -lt 30 ]; then echo "  THIN  dispatch_consistency_audit/SKILL.md"; fail=1
    else echo "  OK    dispatch_consistency_audit/SKILL.md ($n lines)"; fi
  fi
  return $fail
}

check_9_12_B() {
  if [ -x scripts/check_build_dce.sh ]; then
    bash scripts/check_build_dce.sh --gate
    return $?
  fi
  echo "  MISS  scripts/check_build_dce.sh"; return 1
}

check_9_12_C() {
  local fail=0
  if [ -x scripts/check_invariant_comments.sh ]; then
    if ! bash scripts/check_invariant_comments.sh --gate > /tmp/c_invc.log 2>&1; then
      echo "  FAIL  check_invariant_comments --gate"; cat /tmp/c_invc.log; fail=1
    else
      echo "  OK    check_invariant_comments --gate"
    fi
  fi
  local n
  n=$(wc -l < .claude/rules/comment_as_invariant.md 2>/dev/null || echo 0)
  if [ "$n" -ge 30 ]; then echo "  OK    comment_as_invariant.md ($n lines)"
  else echo "  THIN  comment_as_invariant.md ($n lines)"; fail=1; fi
  return $fail
}

check_9_12_D() {
  bash scripts/check_libc_boundary.sh --gate
}

check_9_12_E() {
  bash scripts/check_skip_impl_ratchet.sh --gate
}

check_9_12_F() {
  local n
  n=$(yq -r '[.entries[] | select(.status == "now" or .status == "blocked-by")] | length' .dev/debt.yaml)
  if [ "$n" -lt 15 ]; then echo "  OK    debt active entries: $n (< 15)"; return 0; fi
  echo "  FAIL  debt active entries: $n (>= 15)"; return 1
}

check_9_12_G() {
  bash scripts/zone_check.sh --gate
}

check_9_12_H() {
  if grep -q "p9-close: Wasm-2.0 baseline" bench/results/history.yaml 2>/dev/null; then
    echo "  OK    bench history.yaml has p9-close baseline row"; return 0
  fi
  echo "  FAIL  bench history.yaml missing p9-close baseline row"; return 1
}

check_9_12_I() {
  local fail=0
  if ! bash scripts/check_adr_history.sh --gate > /tmp/c_adr.log 2>&1; then
    echo "  FAIL  check_adr_history --gate"; cat /tmp/c_adr.log; fail=1
  else echo "  OK    check_adr_history --gate"; fi
  if ! bash scripts/check_lesson_citing.sh > /tmp/c_les.log 2>&1; then
    echo "  FAIL  check_lesson_citing"; cat /tmp/c_les.log; fail=1
  else echo "  OK    check_lesson_citing"; fi
  return $fail
}

run_check() {
  local row="$1"
  echo "--- §$row exit check ---"
  case "$row" in
    9.12-A) check_9_12_A ;;
    9.12-B) check_9_12_B ;;
    9.12-C) check_9_12_C ;;
    9.12-D) check_9_12_D ;;
    9.12-E) check_9_12_E ;;
    9.12-F) check_9_12_F ;;
    9.12-G) check_9_12_G ;;
    9.12-H) check_9_12_H ;;
    9.12-I) check_9_12_I ;;
    *)      echo "  (no check registered for §$row)"; return 0 ;;
  esac
}

# --- dispatch ------------------------------------------------------------

if [ -n "$TARGET_ROW" ]; then
  rows=("$TARGET_ROW")
elif [ "$MODE" = "--gate" ]; then
  mapfile -t rows < <(discover_flipped_rows)
  if [ "${#rows[@]}" -eq 0 ]; then
    echo "[check_subrow_exit] OK — no §9.12-X [x] flip in HEAD"
    exit 0
  fi
else
  rows=(9.12-A 9.12-B 9.12-C 9.12-D 9.12-E 9.12-F 9.12-G 9.12-H 9.12-I)
fi

fail=0
for r in "${rows[@]}"; do
  if ! run_check "$r"; then fail=1; fi
  echo ""
done

if [ "$MODE" = "--gate" ] && [ "$fail" -ne 0 ]; then
  echo "[check_subrow_exit] FAIL — one or more sub-row exit criteria unmet"
  exit 1
fi

echo "[check_subrow_exit] OK"
exit 0
