#!/usr/bin/env bash
# scripts/check_adr_history.sh
#
# Walk every .dev/decisions/[0-9]*.md ADR and verify that:
#  - SHAs cited in the Revision history table actually exist in
#    `git log` (catches typos and copy-paste accidents).
#  - `<backfill>` placeholders are flagged as a soft warning so
#    they get filled at the next phase boundary.
#
# Exit code: 0 unless --gate is passed AND a Revision history row
# names a SHA that doesn't resolve.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DECISIONS_DIR="$REPO_ROOT/.dev/decisions"

GATE_MODE=false
if [[ "${1:-}" == "--gate" ]]; then
  GATE_MODE=true
fi

cd "$REPO_ROOT"

shopt -s nullglob
# Number-prefixed ADRs only (skip skip_*.md, README.md, _DRAFT_*.md,
# 0000_template.md).
adr_files=("$DECISIONS_DIR"/[0-9][0-9][0-9][0-9]_*.md)

if [[ ${#adr_files[@]} -eq 0 ]]; then
  echo "No numbered ADRs found in $DECISIONS_DIR/."
  exit 0
fi

echo "ADR Revision-history audit ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
echo "============================================================"

violations=0
backfill_count=0

for f in "${adr_files[@]}"; do
  rel="${f#$REPO_ROOT/}"

  # Only process files that have a Revision history § (header H2
  # with the exact text "Revision history").
  if ! grep -q '^## .*Revision history' "$f"; then
    continue
  fi

  echo
  echo "## $rel"

  # Extract SHA-shaped tokens from the Revision history § only.
  in_rev=false
  while IFS= read -r line; do
    if [[ "$line" =~ ^##[[:space:]].*Revision[[:space:]]history ]]; then
      in_rev=true
      continue
    fi
    case "$line" in
      "## "*) in_rev=false ;;
    esac
    if $in_rev; then
      # Match backticked SHA candidates: `[0-9a-f]{6,40}`.
      while read -r sha; do
        if [[ "$sha" == "<backfill>" ]]; then
          echo "  · backfill pending"
          backfill_count=$((backfill_count + 1))
          continue
        fi
        if [[ -n "$sha" ]]; then
          if git rev-parse --quiet --verify "$sha" >/dev/null 2>&1; then
            short=$(git rev-parse --short "$sha")
            echo "  ✓ $sha  ($short)"
          else
            echo "  ✗ $sha  (UNKNOWN — not in git log)"
            violations=$((violations + 1))
          fi
        fi
      done < <(printf '%s\n' "$line" | grep -oE '`[0-9a-f]{6,40}`|`<backfill>`' | tr -d '`' || true)
    fi
  done <"$f"
done

echo
echo "============================================================"
echo "ADRs with Revision history: $(grep -l '^## .*Revision history' "${adr_files[@]}" 2>/dev/null | wc -l | tr -d ' ')"
echo "Pending backfills (<backfill>): $backfill_count"
echo "Unknown-SHA violations: $violations"

if $GATE_MODE && [[ $violations -gt 0 ]]; then
  exit 1
fi
exit 0
