#!/usr/bin/env bash
# scripts/check_skip_adrs.sh
#
# Walk every .dev/decisions/skip_*.md file and print a summary of
# their stated Removal condition + the fixtures they cover. Does
# not auto-resolve — prints findings for the human / audit_scaffolding
# skill to act on.
#
# Goal: when a skip-ADR's structural barrier is removed (e.g. the
# import-type-validation work lands and embenchen fixtures should
# pass), this script flags that the skip-ADR is now eligible for
# removal.
#
# Exit code: 0 unless --gate is passed AND a skip-ADR's referenced
# fixture path is missing on disk (= the fixture has been deleted
# but the ADR still cites it).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DECISIONS_DIR="$REPO_ROOT/.dev/decisions"

GATE_MODE=false
if [[ "${1:-}" == "--gate" ]]; then
  GATE_MODE=true
fi

shopt -s nullglob
skip_files=("$DECISIONS_DIR"/skip_*.md)

if [[ ${#skip_files[@]} -eq 0 ]]; then
  echo "No skip-ADRs found in $DECISIONS_DIR/."
  exit 0
fi

echo "Skip-ADR audit ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
echo "============================================================"

violations=0

for f in "${skip_files[@]}"; do
  rel="${f#$REPO_ROOT/}"
  echo
  echo "## $rel"

  # Extract Status, Fixtures covered count, Removal condition.
  status=$(awk '/^- \*\*Status\*\*:/ {sub(/.*Status\*\*: /,""); print; exit}' "$f")
  fixtures_count=$(awk '/^- \*\*Fixtures covered\*\*:/ {sub(/.*Fixtures covered\*\*: /,""); print; exit}' "$f")

  echo "Status: ${status:-<missing>}"
  echo "Fixtures covered: ${fixtures_count:-<missing>}"

  # List fixture files referenced (lines in Fixtures § that look
  # like backticked paths).
  in_fixtures=false
  while IFS= read -r line; do
    case "$line" in
      "## Fixture"*|"## Fixtures"*) in_fixtures=true; continue ;;
      "## "*) in_fixtures=false ;;
    esac
    if $in_fixtures; then
      # Extract paths from `path/to/file.wasm` backtick segments.
      while read -r path; do
        if [[ -n "$path" ]]; then
          full="$REPO_ROOT/$path"
          if [[ -e "$full" ]]; then
            echo "  ✓ $path"
          else
            echo "  ✗ $path  (MISSING ON DISK — skip-ADR cites a deleted fixture)"
            violations=$((violations + 1))
          fi
        fi
      done < <(printf '%s\n' "$line" | grep -oE '`[a-zA-Z0-9_./-]+\.wasm`' | tr -d '`' || true)
    fi
  done <"$f"

  # Surface the Removal condition § content (verbatim).
  echo "Removal condition:"
  awk '/^## Removal condition/{flag=1;next}/^## /{flag=0}flag' "$f" \
    | sed 's/^/  /'
done

echo
echo "============================================================"
echo "Prefix-vocab coherence (per ADR-0029 Path B)"
echo "============================================================"

# Per ADR-0029: every `skip-adr-<id>` line in a manifest must
# resolve to an existing `.dev/decisions/skip_<id>.md` file, and
# every `skip_<id>.md` should have ≥ 1 manifest consumer (an
# orphaned skip-ADR is a candidate for removal).

prefix_violations=0

# (1) Every `skip-adr-<id>` prefix in test/ → ADR file exists.
# Each input row is `<file>:<lineno>:<content>`; parse all 3 fields.
declare -A seen_missing_ids=()
while IFS=: read -r path lineno content; do
  prefix=$(printf '%s' "$content" | awk '{print $1}')
  adr_id=${prefix#skip-adr-}
  adr_file="$DECISIONS_DIR/${adr_id}.md"
  if [[ ! -e "$adr_file" ]]; then
    # Print one diagnostic per (file, adr_id); dedupe per file.
    key="${path}::${adr_id}"
    if [[ -z "${seen_missing_ids[$key]:-}" ]]; then
      echo "  ✗ ${path#$REPO_ROOT/}: skip-adr-${adr_id} → MISSING ADR file ${adr_id}.md"
      seen_missing_ids[$key]=1
    fi
    prefix_violations=$((prefix_violations + 1))
  fi
done < <(grep -rEHn '^skip-adr-[a-zA-Z0-9_-]+ ' "$REPO_ROOT/test/" 2>/dev/null || true)

# (2) Every skip_*.md ADR → ≥ 1 manifest consumer.
for f in "${skip_files[@]}"; do
  rel="${f#$REPO_ROOT/}"
  base="$(basename "$f" .md)"
  # Skip closed/superseded ADRs — `Status: Closed (...)` or
  # `Status: Superseded ...` indicates the Removal condition
  # fired (manifest consumers all rewritten out by a distiller
  # regen, OR the skip path was replaced by a real runner-side
  # implementation). Both are historical records per
  # .dev/decisions/README.md, NOT orphans.
  status_line=$(grep -E '^- \*\*Status\*\*:' "$f" | head -1)
  if echo "$status_line" | grep -qE '^- \*\*Status\*\*: (Closed|Superseded)'; then
    echo "  · $rel: Closed/Superseded (skipped — historical record)"
    continue
  fi
  # `grep -rEc` exits 1 when no matches anywhere; under `set -e`
  # + `pipefail` that aborts the whole script before the
  # orphan-detection branch can fire. Wrap with `|| true` so a
  # zero count is reported as legitimate orphan detection rather
  # than masking via early exit (the prior bug masked
  # skip_host_state_diverged + skip_text_format_parser orphans
  # for an unknown duration).
  count=$({ grep -rEc "^skip-adr-${base} " "$REPO_ROOT/test/" 2>/dev/null || true; } \
    | awk -F: '{ s += $2 } END { print s+0 }')
  if [[ "$count" -eq 0 ]]; then
    echo "  ✗ $rel: 0 manifest consumers (orphaned skip-ADR; remove or wire a manifest line)"
    prefix_violations=$((prefix_violations + 1))
  else
    echo "  ✓ $rel: $count manifest line(s) reference skip-adr-${base}"
  fi
done

echo
echo "============================================================"
echo "Total skip-ADRs: ${#skip_files[@]}"
echo "Fixture-path violations: $violations"
echo "Prefix-vocab violations: $prefix_violations"

if $GATE_MODE && [[ $((violations + prefix_violations)) -gt 0 ]]; then
  exit 1
fi
exit 0
