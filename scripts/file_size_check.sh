#!/usr/bin/env bash
# File-size cap enforcement (ROADMAP §A2).
#
# Soft cap (1000 lines): warning, requires ADR for split plan.
# Hard cap (2000 lines): gate fails.
#
# Auto-generated files are exempt: they must contain
# `// AUTO-GENERATED FROM <source>` on lines 1-3.
#
# Modes:
#   bash scripts/file_size_check.sh           informational; warn-only
#   bash scripts/file_size_check.sh --gate    exit 1 on hard-cap violation

set -euo pipefail

SOFT_CAP=1000
HARD_CAP=2000
MODE="${1:-info}"

cd "$(dirname "$0")/.."

violations=0
warnings=0

while IFS= read -r f; do
    [ -z "$f" ] && continue
    lines=$(wc -l < "$f" | tr -d ' ')

    if head -3 "$f" 2>/dev/null | grep -q 'AUTO-GENERATED'; then
        continue
    fi

    if [ "$lines" -gt "$HARD_CAP" ]; then
        echo "HARD CAP EXCEEDED: $f ($lines lines, cap=$HARD_CAP)" >&2
        violations=$((violations + 1))
    elif [ "$lines" -gt "$SOFT_CAP" ]; then
        echo "WARN: $f ($lines lines) — needs ADR for split plan" >&2
        warnings=$((warnings + 1))
    fi
done < <(find src -name '*.zig' 2>/dev/null || true)

if [ "$violations" -gt 0 ]; then
    echo
    echo "$violations file(s) exceed hard cap ($HARD_CAP lines)."
fi
if [ "$warnings" -gt 0 ]; then
    echo "$warnings file(s) exceed soft cap ($SOFT_CAP lines)."
fi

if [ "$MODE" = "--gate" ] && [ "$violations" -gt 0 ]; then
    exit 1
fi

exit 0
