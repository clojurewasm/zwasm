#!/usr/bin/env bash
# Detect on-branch architectural spike patterns (close-plan §6 (d) / D-153 anti-pattern).
#
# Scans recent commits on main for forbidden phrases that historically
# correlated with "helper先 land → wire-up 別 cycle" — the failure mode that consumed
# 12 cycles in D-153 (B146-B158).
#
# Exit codes:
#   0 — no findings (clean)
#   1 — `soon` findings only (in-flight spike pattern, not paired with private/spikes/)
#   2 — `block` findings (spike pattern + missing ADR/spike pairing)
set -euo pipefail

cd "$(dirname "$0")/.."

WINDOW="${1:-14 days ago}"
PHRASES=(
    "preparatory infra"
    "wire-up next cycle"
    "wire-up.*next chunk"
    "helper for.*future"
    "lay the groundwork"
    "groundwork for"
)

# Build alternation pattern.
pattern=""
for p in "${PHRASES[@]}"; do
    if [[ -z "$pattern" ]]; then
        pattern="$p"
    else
        pattern="${pattern}\\|${p}"
    fi
done

hits=$(git log --since="$WINDOW" --grep="$pattern" --extended-regexp --pretty=format:'%h %s' 2>/dev/null || true)

if [[ -z "$hits" ]]; then
    echo "[audit_arch_spike_pattern] OK — no flagged phrases in last $WINDOW"
    exit 0
fi

block_count=0
soon_count=0
echo "[audit_arch_spike_pattern] flagged commits (last $WINDOW):"
while IFS= read -r line; do
    sha="${line%% *}"
    [[ -z "$sha" ]] && continue
    body=$(git log -1 --format='%B' "$sha" 2>/dev/null || true)
    # Paired safety: commit body references private/spikes/ OR an ADR (decisions/NNNN_).
    if echo "$body" | grep -E 'private/spikes/|\.dev/decisions/[0-9]{4}_' > /dev/null; then
        echo "  soon  $line  (paired with spike/ADR — discipline held)"
        soon_count=$((soon_count + 1))
    else
        echo "  block $line  (no paired private/spikes/ or ADR reference)"
        block_count=$((block_count + 1))
    fi
done <<< "$hits"

echo "[audit_arch_spike_pattern] summary: block=${block_count} soon=${soon_count}"
if (( block_count > 0 )); then
    exit 2
fi
exit 1
