#!/usr/bin/env bash
# scripts/check_skip_taxonomy_pairing.sh — Resolve ADR-0078 Paired artifact refs.
#
# Sibling to scripts/check_skip_taxonomy.sh (which verifies emitted vs. table
# coverage). This script extends audit_scaffolding §G.1.2 (added 2026-05-21;
# ADR-0078 paired follow-up): for each row in ADR-0078's canonical token-class
# table, verify the Paired artifact column's reference resolves.
#
# Classification of the Paired artifact column:
#   - "D-NNN ..."                  → check .dev/debt.yaml for active row
#                                    OR `git log --grep` for discharge SHA;
#                                    if discharged → drift finding.
#   - ".dev/decisions/<file>.md"  → check file exists.
#   - "... D-NNN follow-up"        → unfiled debt placeholder → soon.
#   - "per-fixture D-NNN ..." etc. → generic per-instance deferral → info.
#   - runner-internal class        → no external artifact required.
#
# Usage:
#   bash scripts/check_skip_taxonomy_pairing.sh           # report mode
#   bash scripts/check_skip_taxonomy_pairing.sh --gate    # exit 1 on drift

set -uo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  sed -n '2,20p' "$0"
  exit 0
fi

MODE="${1:-report}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ADR="$ROOT/.dev/decisions/0078_spec_runner_skip_token_taxonomy.md"
DEBT="$ROOT/.dev/debt.yaml"

if [ ! -f "$ADR" ]; then
  echo "[check_skip_taxonomy_pairing] FAIL — $ADR not found"
  exit 1
fi

# Emit one line per table row: TOKEN<TAB>CLASS<TAB>ARTIFACT.
# Filter to the three valid classes; ignore the header row.
rows=$(awk -F'|' '
  /^\|[[:space:]]*`SKIP-/ {
    tok=$2; cls=$3; art=$4
    gsub(/[`]/, "", tok); gsub(/[`]/, "", cls)
    sub(/^[[:space:]]+/, "", tok); sub(/[[:space:]]+$/, "", tok)
    sub(/^[[:space:]]+/, "", cls); sub(/[[:space:]]+$/, "", cls)
    sub(/^[[:space:]]+/, "", art); sub(/[[:space:]]+$/, "", art)
    if (tok ~ /^SKIP-/ && (cls == "debt-trackable" || cls == "ADR-required" || cls == "runner-internal"))
      printf "%s\t%s\t%s\n", tok, cls, art
  }
' "$ADR")

if [ -z "$rows" ]; then
  echo "[check_skip_taxonomy_pairing] FAIL — could not parse any rows from ADR-0078"
  exit 1
fi

# Cache discharge SHAs per debt id ("D-NNN" → "<sha>" or empty).
debt_active() {
  local id="$1"
  D_ID="$id" yq -e '.entries[] | select(.id == env(D_ID))' "$DEBT" >/dev/null 2>&1 && return 0
  return 1
}

debt_discharged_sha() {
  local id="$1"
  local sha
  # Try several verbs the discharge convention has used over time.
  for verb in close discharge closes discharged fix; do
    sha=$(git log --all --oneline --grep="${verb} ${id}\b" 2>/dev/null | head -1 | awk '{print $1}')
    if [ -n "$sha" ]; then printf '%s\n' "$sha"; return; fi
  done
}

active_count=0
ok_internal_count=0
adr_resolved_count=0
debt_active_count=0
drift_discharged_count=0
unfiled_count=0
info_per_instance_count=0
block_missing_file_count=0
findings_block=()
findings_soon=()
findings_info=()

while IFS=$'\t' read -r tok cls art; do
  active_count=$((active_count + 1))
  case "$cls" in
    runner-internal)
      ok_internal_count=$((ok_internal_count + 1))
      ;;
    ADR-required)
      file=$(printf '%s' "$art" | grep -oE '\.dev/decisions/[A-Za-z0-9_./-]+\.md' | head -1)
      if [ -z "$file" ]; then
        findings_block+=("$tok: ADR-required class lacks .dev/decisions/*.md reference (artifact: '$art')")
        continue
      fi
      if [ -f "$ROOT/$file" ]; then
        adr_resolved_count=$((adr_resolved_count + 1))
      else
        findings_block+=("$tok: ADR file '$file' not found")
        block_missing_file_count=$((block_missing_file_count + 1))
      fi
      ;;
    debt-trackable)
      # Match a specific D-NNN id at the START of the artifact text (e.g. "D-152 (..." vs. "per-fixture D-NNN as discovered").
      id=$(printf '%s' "$art" | grep -oE '^D-[0-9]+' | head -1)
      if [ -n "$id" ]; then
        if debt_active "$id"; then
          debt_active_count=$((debt_active_count + 1))
        else
          sha=$(debt_discharged_sha "$id")
          if [ -n "$sha" ]; then
            # If the artifact text already cites the discharge SHA inline,
            # the row is intentionally pointing at the discharged state —
            # not drift. Otherwise the column is stale.
            if printf '%s' "$art" | grep -qF "$sha"; then
              debt_active_count=$((debt_active_count + 1))
            else
              findings_soon+=("$tok: paired debt $id discharged at $sha but row still cited in ADR-0078 — update Paired artifact column (cite discharge SHA or remove SKIP-* emission if the gap dissolved)")
              drift_discharged_count=$((drift_discharged_count + 1))
            fi
          else
            findings_soon+=("$tok: paired debt $id neither active nor found in discharge history")
            drift_discharged_count=$((drift_discharged_count + 1))
          fi
        fi
      elif printf '%s' "$art" | grep -qE 'D-NNN'; then
        # Placeholder reference — unfiled per-fixture deferrals or follow-ups.
        if printf '%s' "$art" | grep -qE 'follow-up'; then
          findings_soon+=("$tok: 'D-NNN follow-up' placeholder — file the actual debt row OR retire the placeholder")
          unfiled_count=$((unfiled_count + 1))
        else
          # "per-fixture D-NNN as discovered" / "per-corpus D-NNN" / "per-call D-NNN"
          findings_info+=("$tok: per-instance D-NNN deferral ('$art') — debts get filed when fixtures hit; no action required")
          info_per_instance_count=$((info_per_instance_count + 1))
        fi
      elif printf '%s' "$art" | grep -qiE 'inventory-only'; then
        # Inventory-only rows: the token is registered in the table but
        # not currently emitted by `test/spec/` source. The row is
        # forward-looking documentation, not a paired-artifact drift.
        findings_info+=("$tok: inventory-only (token not currently emitted) — no action required")
        info_per_instance_count=$((info_per_instance_count + 1))
      else
        # debt-trackable without any D-NNN reference at all.
        findings_soon+=("$tok: debt-trackable but artifact lacks any D-NNN reference (artifact: '$art')")
      fi
      ;;
  esac
done <<< "$rows"

# --- report --------------------------------------------------------------

echo "=== ADR-0078 paired-artifact resolution (audit §G.1.2) ==="
echo "rows scanned:           $active_count"
echo "  runner-internal:      $ok_internal_count (no external artifact required)"
echo "  ADR resolved:         $adr_resolved_count"
echo "  debt-active:          $debt_active_count"
echo "  drift (discharged):   $drift_discharged_count"
echo "  unfiled (D-NNN ph):   $unfiled_count"
echo "  per-instance defer:   $info_per_instance_count"
echo "  block (missing file): $block_missing_file_count"
echo ""

if [ "${#findings_block[@]}" -gt 0 ]; then
  echo "BLOCK findings:"
  for f in "${findings_block[@]}"; do echo "  - $f"; done
  echo ""
fi
if [ "${#findings_soon[@]}" -gt 0 ]; then
  echo "SOON findings (drift; update ADR-0078 Paired artifact column):"
  for f in "${findings_soon[@]}"; do echo "  - $f"; done
  echo ""
fi
if [ "${#findings_info[@]}" -gt 0 ]; then
  echo "INFO (per-instance deferrals; no action):"
  for f in "${findings_info[@]}"; do echo "  - $f"; done
  echo ""
fi

if [ "${#findings_block[@]}" -gt 0 ]; then
  if [ "$MODE" = "--gate" ]; then
    echo "[check_skip_taxonomy_pairing] FAIL — ${#findings_block[@]} block finding(s)"
    exit 1
  fi
  echo "[check_skip_taxonomy_pairing] WARN — ${#findings_block[@]} block finding(s) (would FAIL in --gate mode)"
  exit 0
fi

echo "[check_skip_taxonomy_pairing] OK — no block findings"
exit 0
