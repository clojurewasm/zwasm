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
echo "Total skip-ADRs: ${#skip_files[@]}"
echo "Fixture-path violations: $violations"

if $GATE_MODE && [[ $violations -gt 0 ]]; then
  exit 1
fi
exit 0
