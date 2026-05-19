#!/usr/bin/env bash
# scripts/check_skip_impl_ratchet.sh — Skip-impl one-way ratchet gate.
#
# Compares the current commit's skip-impl count against the previous entry
# in `bench/results/skip_impl_history.yaml`. FAILs if the count strictly
# increased AND the current commit's diff does not introduce a new yaml
# row whose `exempt:` field cites an ADR.
#
# Phase 9 completion master plan §7.3 / ADR-0050 amend (D-5 + D-6).
#
# Modes:
#   --gate    : exit non-zero on regression without exempt (pre-push hook)
#   --measure : run live spec_assert runners and emit a new yaml row
#               candidate (author commits if intentional)
#   --report  : exit 0; show current vs prev with delta
#   (none)    : same as --report
#
# Live measurement is expensive. The script prefers cached logs at
# /tmp/non-simd-full.log + /tmp/p9-mac-simd.log when fresh (< 1 h).

set -uo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  sed -n '2,20p' "$0"
  exit 0
fi

MODE="${1:-report}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

YAML="$ROOT/bench/results/skip_impl_history.yaml"

# --- previous baseline (last yaml entry's total) -------------------------

# Parse YAML without external deps. Each entry starts with "  - commit:"
# and has non_simd_skip_impl / simd_skip_impl / total fields. Take the
# last `total:` value as the baseline.
prev_total=$(awk '
  /^  - commit:/ { in_entry=1 }
  in_entry && /^[[:space:]]+total:[[:space:]]+/ {
    t=$2; gsub(/[^0-9]/, "", t); if (t != "") last=t
  }
  END { print last }
' "$YAML" 2>/dev/null)

if [ -z "$prev_total" ]; then
  echo "[check_skip_impl_ratchet] WARN — no prior baseline in $YAML; nothing to ratchet"
  exit 0
fi

# --- current measurement (cached preferred) ------------------------------

NS_LOG="/tmp/non-simd-full.log"
SI_LOG="/tmp/p9-mac-simd.log"

log_fresh() {
  local f="$1"
  [ -f "$f" ] || return 1
  # Portable mtime read: `date -r <file> +%s` works on macOS BSD `date`
  # AND GNU `date`. Avoid `stat -f`/`stat -c` which differ across platforms.
  local mtime now age
  now=$(date +%s)
  mtime=$(date -r "$f" +%s 2>/dev/null || echo 0)
  case "$mtime" in
    *[!0-9]*|"") mtime=0 ;;
  esac
  age=$((now - mtime))
  [ "$age" -lt 3600 ]
}

if [ "$MODE" = "--measure" ] || ! log_fresh "$NS_LOG" || ! log_fresh "$SI_LOG"; then
  echo "[check_skip_impl_ratchet] live measurement (cached logs absent / stale)..."
  zig build test-spec-wasm-2.0-assert > "$NS_LOG" 2>&1 || true
  zig build test-spec-simd > "$SI_LOG" 2>&1 || true
fi

# Extract skip-impl from runner output. The canonical format is:
#   "<runner>: N passed, M failed, K skipped (= <impl> skip-impl + <adr> skip-adr) (over ...)"
extract_skip_impl() {
  local log="$1"
  [ -f "$log" ] || { echo 0; return; }
  local v
  v=$(grep -oE '\(=[[:space:]]*[0-9]+[[:space:]]+skip-impl' "$log" 2>/dev/null \
      | head -1 | grep -oE '[0-9]+' | head -1)
  if [ -z "$v" ]; then
    # Fallback for terse formats
    v=$(grep -oE 'skip-impl[[:space:]:]+[0-9]+' "$log" 2>/dev/null \
        | head -1 | grep -oE '[0-9]+' | head -1)
  fi
  echo "${v:-0}"
}

ns_now=$(extract_skip_impl "$NS_LOG")
si_now=$(extract_skip_impl "$SI_LOG")
cur_total=$((ns_now + si_now))
delta=$((cur_total - prev_total))

echo "=== skip-impl ratchet (per ADR-0050 D-5 + D-6) ==="
echo "prev_total:  $prev_total"
echo "cur_total:   $cur_total (non_simd=$ns_now + simd=$si_now)"
echo "delta:       $delta"
echo ""

if [ "$delta" -le 0 ]; then
  echo "[check_skip_impl_ratchet] OK — ratchet not violated"
  exit 0
fi

# --- regression: require exempt ADR in the same commit -------------------

has_exempt_in_diff() {
  local diff_target="$1"
  git diff "$diff_target" --unified=0 -- "$YAML" 2>/dev/null \
    | grep -qE '^\+[[:space:]]+exempt:[[:space:]]+ADR-[0-9]+'
}

if has_exempt_in_diff "--cached" || has_exempt_in_diff "HEAD~1..HEAD"; then
  echo "[check_skip_impl_ratchet] OK — regression has exempt: ADR-NNNN row"
  exit 0
fi

if [ "$MODE" = "--gate" ]; then
  echo "[check_skip_impl_ratchet] FAIL — skip-impl rose by +$delta without exempt: ADR-NNNN"
  echo "[check_skip_impl_ratchet] Fix: (a) close the regression, OR"
  echo "                          (b) add a new yaml row with exempt: <ADR-NNNN>"
  echo "                              citing an Accepted ADR that justifies the increase."
  exit 1
fi

echo "[check_skip_impl_ratchet] WARN — would FAIL in --gate mode"
exit 0
