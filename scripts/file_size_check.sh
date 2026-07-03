#!/usr/bin/env bash
# File-size cap check (ROADMAP §A2) — ADVISORY only.
#
# ADR-0099 (amended 2026-07-03: hard cap is advisory, not a commit
# block — the smell-detector premise ended post-v2.0.0). This check
# NEVER fails; it is informational only, printing WARN / EXEMPT
# signal lines. The authoritative merge gate is CI's ci-required.
#
# Soft cap (1000 lines): WARN, suggests ADR for split plan,
#   UNLESS the file declares the FILE-SIZE-EXEMPT marker — in which
#   case the marker suppresses the WARN per ADR-0099 D1 (reframe:
#   soft cap is a smell detector, not a metric to drive to zero;
#   the marker captures "smell investigated, no valid extraction").
# Hard cap (2000 lines): WARN (advisory since the 2026-07-03
#   amendment; was a gate block pre-v2.0.0).
# Exempt hard cap (2500 lines) / per-file `(cap=N)` / `(cap=UNCAPPED)`:
#   the FILE-SIZE-EXEMPT marker still SUPPRESSES the WARN for
#   investigated files (useful signal management). The marker MUST
#   cite an ADR — silent exemption is forbidden (per ADR-0064
#   §"Forbidden anti-patterns").
#
# Auto-generated files are exempt regardless of cap: they must
# contain `// AUTO-GENERATED FROM <source>` on lines 1-3.
#
# Modes:
#   bash scripts/file_size_check.sh           informational; warn-only
#   bash scripts/file_size_check.sh --gate    same output; still exits 0
#                                             (advisory — never blocks)

set -euo pipefail

SOFT_CAP=1000
HARD_CAP=2000
EXEMPT_CAP=2500
MODE="${1:-info}"

cd "$(dirname "$0")/.."

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
    #
    # Per ADR-0099 Revision 2026-05-24 — optional `(cap=N)`
    # suffix in the marker raises the effective hard cap to N
    # (must be > EXEMPT_CAP). Narrow per-file mechanism for
    # monotonic catalogs that grow with an external axis;
    # rationale must still cite an ADR. Today's only site:
    # entry.zig at cap=3000 per D-168 close.
    exempt=0
    per_file_cap=0
    uncapped=0
    marker_line=$(head -5 "$f" 2>/dev/null | grep -E '^// FILE-SIZE-EXEMPT:.*ADR-[0-9]+' | head -1 || true)
    if [ -n "$marker_line" ]; then
        exempt=1
        cap_extract=$(echo "$marker_line" | sed -nE 's/.*\(cap=([0-9]+)\).*/\1/p' || true)
        if [ -n "$cap_extract" ] && [ "$cap_extract" -gt "$EXEMPT_CAP" ]; then
            per_file_cap=$cap_extract
        fi
        # `(cap=UNCAPPED)` — designated irreducible catalog with NO line cap
        # (user-ratified 2026-06-22 for the C-ABI translation file: a flat list of
        # thin per-entity wrappers, not a smell-bearing subsystem; the line metric
        # is a poor fit). Requires the ADR-ref marker like any exemption.
        if echo "$marker_line" | grep -q '(cap=UNCAPPED)'; then
            uncapped=1
        fi
    fi

    effective_hard_cap=$HARD_CAP
    if [ "$exempt" -eq 1 ]; then
        if [ "$per_file_cap" -gt 0 ]; then
            effective_hard_cap=$per_file_cap
        else
            effective_hard_cap=$EXEMPT_CAP
        fi
    fi

    if [ "$uncapped" -eq 1 ]; then
        echo "EXEMPT-UNCAPPED: $f ($lines lines) — designated irreducible catalog, no line cap (user-ratified 2026-06-22; FILE-SIZE-EXEMPT marker)" >&2
    elif [ "$lines" -gt "$effective_hard_cap" ]; then
        # Over the hard cap (advisory since ADR-0099 amended 2026-07-03):
        # emit a WARN, never a violation. A cap-citing marker still shifts
        # the wording but no longer blocks.
        if [ "$per_file_cap" -gt 0 ]; then
            echo "WARN: $f ($lines lines, per-file-cap=$per_file_cap) — exceeds even the per-file override cap (advisory per ADR-0099 amended 2026-07-03)" >&2
        elif [ "$exempt" -eq 1 ]; then
            echo "WARN: $f ($lines lines, exempt-cap=$EXEMPT_CAP) — exceeds even the exempt cap (advisory per ADR-0099 amended 2026-07-03)" >&2
        else
            echo "WARN: $f ($lines lines, hard-cap=$HARD_CAP) — over hard cap (advisory per ADR-0099 amended 2026-07-03)" >&2
        fi
        warnings=$((warnings + 1))
    elif [ "$lines" -gt "$EXEMPT_CAP" ] && [ "$per_file_cap" -gt 0 ]; then
        echo "EXEMPT: $f ($lines lines, in [$EXEMPT_CAP, $per_file_cap] via per-file (cap=$per_file_cap) override per ADR-0099 Revision 2026-05-24)" >&2
    elif [ "$lines" -gt "$HARD_CAP" ] && [ "$exempt" -eq 1 ]; then
        echo "EXEMPT: $f ($lines lines, in [$HARD_CAP, $EXEMPT_CAP] via FILE-SIZE-EXEMPT marker)" >&2
    elif [ "$lines" -gt "$SOFT_CAP" ] && [ "$exempt" -eq 1 ]; then
        echo "EXEMPT: $f ($lines lines, in [$SOFT_CAP, $HARD_CAP] via FILE-SIZE-EXEMPT marker per ADR-0099 D1)" >&2
    elif [ "$lines" -gt "$SOFT_CAP" ]; then
        echo "WARN: $f ($lines lines) — needs ADR for split plan OR FILE-SIZE-EXEMPT marker (per ADR-0099 D1)" >&2
        warnings=$((warnings + 1))
    fi
done < <(find src -name '*.zig' 2>/dev/null || true)

if [ "$warnings" -gt 0 ]; then
    echo
    echo "$warnings file(s) over a cap (advisory — informational only, never blocks)."
fi

# ADR-0099 (amended 2026-07-03): file size is advisory. `--gate` prints the
# same WARN/EXEMPT lines but ALWAYS exits 0 — CI's ci-required is the merge gate.
exit 0
