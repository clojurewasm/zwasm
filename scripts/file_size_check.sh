#!/usr/bin/env bash
# File-size cap enforcement (ROADMAP §A2).
#
# Soft cap (1000 lines): warning, requires ADR for split plan,
#   UNLESS the file declares the FILE-SIZE-EXEMPT marker — in which
#   case the marker suppresses the WARN per ADR-0099 D1 (reframe:
#   soft cap is a smell detector, not a metric to drive to zero;
#   the marker captures "smell investigated, no valid extraction").
# Hard cap (2000 lines): gate fails.
# Exempt hard cap (2500 lines): allowed only when the file
#   declares `// FILE-SIZE-EXEMPT: <reason> (per ADR-NNNN)`
#   on lines 1-5. The marker MUST cite an ADR — silent exemption
#   is forbidden (per ADR-0064 §"Forbidden anti-patterns").
#
# Auto-generated files are exempt regardless of cap: they must
# contain `// AUTO-GENERATED FROM <source>` on lines 1-3.
#
# Modes:
#   bash scripts/file_size_check.sh           informational; warn-only
#   bash scripts/file_size_check.sh --gate    exit 1 on hard-cap violation

set -euo pipefail

SOFT_CAP=1000
HARD_CAP=2000
EXEMPT_CAP=2500
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

    # Per-file exemption — marker must cite an ADR. The marker
    # serves two purposes per ADR-0099 D1 (reframe):
    #   - [SOFT, HARD] range: suppresses the soft-cap WARN (the
    #     file has been investigated; no design smell present)
    #   - [HARD, EXEMPT_CAP] range: raises the hard cap (catalog
    #     pattern; legitimate uniform-pattern file > 2000 LOC)
    exempt=0
    if head -5 "$f" 2>/dev/null | grep -qE '^// FILE-SIZE-EXEMPT:.*ADR-[0-9]+'; then
        exempt=1
    fi

    effective_hard_cap=$HARD_CAP
    if [ "$exempt" -eq 1 ]; then
        effective_hard_cap=$EXEMPT_CAP
    fi

    if [ "$lines" -gt "$effective_hard_cap" ]; then
        if [ "$exempt" -eq 1 ]; then
            echo "EXEMPT-CAP EXCEEDED: $f ($lines lines, exempt-cap=$EXEMPT_CAP) — even the exempt cap is exceeded" >&2
        else
            echo "HARD CAP EXCEEDED: $f ($lines lines, cap=$HARD_CAP)" >&2
        fi
        violations=$((violations + 1))
    elif [ "$lines" -gt "$HARD_CAP" ] && [ "$exempt" -eq 1 ]; then
        echo "EXEMPT: $f ($lines lines, in [$HARD_CAP, $EXEMPT_CAP] via FILE-SIZE-EXEMPT marker)" >&2
    elif [ "$lines" -gt "$SOFT_CAP" ] && [ "$exempt" -eq 1 ]; then
        echo "EXEMPT: $f ($lines lines, in [$SOFT_CAP, $HARD_CAP] via FILE-SIZE-EXEMPT marker per ADR-0099 D1)" >&2
    elif [ "$lines" -gt "$SOFT_CAP" ]; then
        echo "WARN: $f ($lines lines) — needs ADR for split plan OR FILE-SIZE-EXEMPT marker (per ADR-0099 D1)" >&2
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
