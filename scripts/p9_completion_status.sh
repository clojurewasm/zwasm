#!/usr/bin/env bash
# scripts/p9_completion_status.sh — Phase 9 completion live progress.
#
# Reads `.dev/p9_completion_progress.yaml` and reconciles it against
# current state (per-op file count, skip-impl counters, enforcement-layer
# wiring, debt `now` rows). Output is authoritative; handover narrative
# quotes this script rather than predicting (per
# `.claude/rules/no_handover_predictions.md`).
#
# Phase 9 completion master plan §7.8.

set -uo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  sed -n '2,12p' "$0"
  exit 0
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
YAML="$ROOT/.dev/p9_completion_progress.yaml"
HIST="$ROOT/bench/results/skip_impl_history.yaml"

echo "=== Phase 9 completion — live progress ==="
echo "(generated $(date '+%Y-%m-%d %H:%M:%S'))"
echo ""

# --- sub-row status from progress yaml ----------------------------------

if [ ! -f "$YAML" ]; then
  echo "[warn] $YAML not found"
else
  echo "--- §9.12-X sub-row status (from progress yaml) ---"
  awk '
    /^[[:space:]]+- id:[[:space:]]+"/ {
      gsub(/"/, "", $3); id=$3
    }
    /^[[:space:]]+status:[[:space:]]+/ {
      st=$2
      printf "  %-12s %s\n", id, st
    }
  ' "$YAML"
  echo ""
fi

# --- skip-impl history latest baseline ----------------------------------

if [ -f "$HIST" ]; then
  echo "--- skip-impl ratchet baseline (latest yaml row) ---"
  awk '
    /^  - commit:/ { in_entry=1; commit=$3 }
    in_entry && /^[[:space:]]+timestamp:/ { ts=$2 }
    in_entry && /^[[:space:]]+non_simd_skip_impl:/ { ns=$2 }
    in_entry && /^[[:space:]]+simd_skip_impl:/ { si=$2 }
    in_entry && /^[[:space:]]+total:/ { tot=$2; last_commit=commit; last_ts=ts; last_ns=ns; last_si=si; last_tot=tot }
    END {
      gsub(/"/, "", last_commit); gsub(/"/, "", last_ts)
      printf "  commit:    %s\n  timestamp: %s\n  non_simd:  %s\n  simd:      %s\n  total:     %s\n", last_commit, last_ts, last_ns, last_si, last_tot
    }
  ' "$HIST"
  echo ""
fi

# --- debt sweep ---------------------------------------------------------

echo "--- debt 'now' rows ---"
n_now=$(awk '
  /^## Active/ { active=1; next }
  /^## / { active=0 }
  active && /^### D-/ { id=$2 }
  active && /^- Status:[[:space:]]*now/ { print id }
' "$ROOT/.dev/debt.md" | wc -l | tr -d ' ')
echo "  now rows: $n_now"
if [ "$n_now" -gt 0 ]; then
  awk '
    /^## Active/ { active=1; next }
    /^## / { active=0 }
    active && /^### D-/ { id=$0 }
    active && /^- Status:[[:space:]]*now/ { print "  " id }
  ' "$ROOT/.dev/debt.md"
fi
echo ""

# --- enforcement-layer 9 items wiring -----------------------------------

echo "--- enforcement layer (master plan §7.1-7.9) ---"
check_item() {
  local label="$1" path="$2" min_lines="$3"
  if [ ! -f "$path" ] && [ ! -d "$path" ]; then
    printf "  MISS  %-20s %s\n" "$label" "$path"; return
  fi
  if [ -f "$path" ]; then
    local n=$(wc -l < "$path")
    if [ "$n" -lt "$min_lines" ]; then
      printf "  THIN  %-20s %s (%d lines, < %d)\n" "$label" "$path" "$n" "$min_lines"
    else
      printf "  OK    %-20s %s (%d lines)\n" "$label" "$path" "$n"
    fi
  else
    printf "  OK    %-20s %s (dir)\n" "$label" "$path"
  fi
}
check_item "7.1 build-DCE"      "scripts/check_build_dce.sh" 50
check_item "7.2 per-op comptime" "src/ir/dispatch_collector.zig" 20
check_item "7.3 skip-impl ratchet" "scripts/check_skip_impl_ratchet.sh" 50
check_item "7.4 fallback-detect" "scripts/check_fallback_patterns.sh" 50
check_item "7.5 spike-lifecycle" ".claude/rules/spike_lifecycle.md" 30
check_item "7.6 subrow-exit"     "scripts/check_subrow_exit.sh" 50
check_item "7.7 dispatch-audit"  ".claude/skills/dispatch_consistency_audit/SKILL.md" 30
check_item "7.8 progress-status" "scripts/p9_completion_status.sh" 50
check_item "7.9 feature-level"   "src/ir/feature_level_check.zig" 10

echo ""
echo "[p9_completion_status] done"
exit 0
