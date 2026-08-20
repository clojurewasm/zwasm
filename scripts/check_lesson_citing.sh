#!/usr/bin/env bash
# Lint .dev/lessons/*.md for unfilled `<backfill>` / `TBD` / `pending`
# markers in the **Citing** header. Per .claude/rules/lessons_vs_adr.md,
# `Citing:` records the commit SHA (or §-row reference) tying the
# lesson to the production change that motivated it. `<backfill>` is
# acceptable until the commit lands; phase-boundary backfill is
# mandatory.
#
# Usage:
#   bash scripts/check_lesson_citing.sh          # warn only (exit 0)
#   bash scripts/check_lesson_citing.sh --strict # exit 1 if any unfilled
#
# Excludes _TEMPLATE.md (the template itself contains `<backfill>` as
# placeholder).

set -uo pipefail

cd "$(dirname "$0")/.."

strict=0
case "${1:-}" in
  --strict) strict=1 ;;
  "") ;;
  *) echo "usage: $0 [--strict]" >&2; exit 2 ;;
esac

count=0
for f in .dev/lessons/*.md; do
  case "$f" in
    .dev/lessons/INDEX.md|.dev/lessons/_TEMPLATE.md) continue ;;
  esac
  # Match both top-level `**Citing**:` and list-bullet `- **Citing**:`
  # forms (early lessons used the latter; _TEMPLATE.md prescribes the
  # former).
  if grep -nE '\*\*Citing\*\*.*<(backfill|TBD|pending)>' "$f" >/dev/null 2>&1; then
    line=$(grep -nE '\*\*Citing\*\*.*<(backfill|TBD|pending)>' "$f" | head -1)
    echo "WARN  $f: unfilled Citing marker"
    echo "      $line"
    count=$((count + 1))
  fi
done

if [ "$count" -eq 0 ]; then
  echo "OK: all lessons have resolved Citing fields"
  exit 0
fi

echo ""
echo "$count lesson(s) have unfilled <backfill>/TBD/pending Citing markers."
echo "Backfill when you next touch the lesson, or during an audit_scaffolding run (§F)."

if [ "$strict" -eq 1 ]; then
  exit 1
fi
exit 0
