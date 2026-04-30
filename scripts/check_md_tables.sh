#!/usr/bin/env bash
# Markdown table format check — invoked as PreToolUse hook by Claude Code.
# Reads JSON payload from stdin; only acts when the embedded `command`
# is `git commit`. For other tool uses, exits 0 silently.

set -euo pipefail

input=$(cat)
case "$input" in
    *'"git commit"'*) ;;
    *) exit 0 ;;
esac

REPO=${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || echo .)}
cd "$REPO"

# Find staged .md files
staged=$(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null | grep '\.md$' || true)
[ -z "$staged" ] && exit 0

bad=0
for f in $staged; do
    [ ! -f "$f" ] && continue
    awk '
        /^\|/ {
            n = gsub(/\|/, "|");
            if (last_n > 0 && n != last_n) {
                printf "%s:%d: pipe count mismatch (%d vs prev %d)\n", FILENAME, NR, n, last_n
                exit 1
            }
            last_n = n
        }
        !/^\|/ { last_n = 0 }
    ' "$f" || bad=$((bad + 1))
done

[ "$bad" -gt 0 ] && exit 1 || exit 0
