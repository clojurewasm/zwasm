#!/usr/bin/env bash
# Check `.dev/proposal_watch.md` "Last reviewed" freshness (§14.3 nightly).
# The proposal watch is reviewed quarterly (90 days); this flags drift so
# the WebAssembly-proposal phase table gets re-evaluated on cadence.
#
#   bash scripts/check_proposal_watch.sh [--gate]
#     default : warn if stale, exit 0.
#     --gate  : exit 1 if stale (the nightly turns staleness into a red check).
set -euo pipefail
cd "$(dirname "$0")/.."

GATE=0
[ "${1:-}" = "--gate" ] && GATE=1

DOC=.dev/proposal_watch.md
reviewed=$(grep -oE 'Last reviewed: \*\*[0-9]{4}-[0-9]{2}-[0-9]{2}\*\*' "$DOC" \
  | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1 || true)
if [ -z "$reviewed" ]; then
  echo "[check_proposal_watch] no 'Last reviewed: **YYYY-MM-DD**' line in $DOC" >&2
  exit 2
fi

age=$(python3 -c "import datetime; print((datetime.date.today()-datetime.date.fromisoformat('$reviewed')).days)")
echo "[check_proposal_watch] last reviewed $reviewed ($age days ago; quarterly cadence = 90d)"
if [ "$age" -gt 90 ]; then
  echo "[check_proposal_watch] STALE — re-review the WebAssembly proposal phases ($DOC) + bump the date" >&2
  [ "$GATE" = 1 ] && exit 1
fi
echo "[check_proposal_watch] OK — within cadence."
