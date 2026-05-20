#!/usr/bin/env bash
# scripts/backfill_adr_shas.sh — Replace `<backfill>` placeholders in
# `.dev/decisions/*.md` Revision-history rows with the unique commit
# SHA that touched the ADR file on the row's stated date.
#
# Rules:
# - A `<backfill>` row's date is the date prefix on the same line or
#   the nearest line above (allow ` - **YYYY-MM-DD**` / `| YYYY-MM-DD`).
# - Find commits in `git log --follow -- <file>` whose author date
#   matches the row's date. If exactly one commit matches AND that
#   commit's diff for the file does NOT remove a `<backfill>` row
#   (cheap heuristic against self-modifying commits), replace the
#   placeholder with the SHA. Skip on 0/multiple matches.
#
# Modes:
#   bash scripts/backfill_adr_shas.sh           # dry-run: list candidates
#   bash scripts/backfill_adr_shas.sh --apply   # mutate files in place

set -uo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-dry}"

filled=0
skipped_zero=0
skipped_multi=0
candidates=()

for adr in .dev/decisions/*.md; do
    grep -q "<backfill>" "$adr" || continue
    base="$(basename "$adr")"
    # Iterate lines containing <backfill>.
    while IFS= read -r line; do
        # Extract a YYYY-MM-DD prefix from the line itself.
        date=$(printf '%s' "$line" | grep -oE '20[2-9][0-9]-[0-9]{2}-[0-9]{2}' | head -1)
        [ -n "$date" ] || continue
        # Find unique commit on that date touching the file.
        shas=$(git log --follow --pretty='%h %ad' --date=short -- "$adr" \
            | awk -v d="$date" '$2 == d { print $1 }')
        n=$(printf '%s\n' "$shas" | grep -c .)
        if [ "$n" -eq 0 ]; then
            skipped_zero=$((skipped_zero + 1))
        elif [ "$n" -gt 1 ]; then
            skipped_multi=$((skipped_multi + 1))
        else
            sha=$shas
            # Defensive: never replace a placeholder with a SHA whose own
            # commit body introduces this <backfill> token (i.e. the
            # placeholder didn't exist before that commit).
            if git show -- "$sha" -- "$adr" 2>/dev/null | grep -q '^+.*<backfill>'; then
                skipped_zero=$((skipped_zero + 1))
                continue
            fi
            candidates+=("$adr|$date|$sha")
            filled=$((filled + 1))
        fi
    done < <(grep "<backfill>" "$adr")
done

echo "Backfill candidates ($filled rows; skipped $skipped_zero zero / $skipped_multi multi):"
for c in "${candidates[@]}"; do
    IFS='|' read -r f d s <<< "$c"
    echo "  $f  $d  → $s"
done

if [ "$MODE" = "--apply" ]; then
    echo
    echo "Applying ..."
    for c in "${candidates[@]}"; do
        IFS='|' read -r f d s <<< "$c"
        # Replace the first <backfill> on a line matching the date.
        # Use perl for non-greedy single-row replacement.
        perl -i -pe 'BEGIN{$d=shift @ARGV;$s=shift @ARGV;$done=0}
                     if(!$done && /\Q$d\E/ && s/<backfill>/$s/){$done=1}' \
            "$d" "$s" "$f"
    done
    echo "Done."
fi
