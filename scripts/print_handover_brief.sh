#!/usr/bin/env bash
# scripts/print_handover_brief.sh — emit the resume brief that
# SessionStart and PostCompact hooks inject into Claude's context.
#
# Single source of truth for the brief shape: language policy +
# `.dev/handover.md` body + last 3 git commits. Used by:
#   - SessionStart hook (cold-start every session)
#   - PostCompact hook (re-inject after autoCompact mid-session)
#
# Stdout is the brief; stderr is suppressed. Exits 0 even when
# handover or git fail — the hook should never block the agent.

set -u

CTX="${CLAUDE_PROJECT_DIR:-$(dirname "$0")/..}"

printf '=== language policy ===\n'
printf 'Reply to the user in Japanese (画面表示は日本語). Code, identifiers, file paths, commit messages, and English docs stay in English. See .claude/output_styles/japanese.md.\n\n'

if [ -f "$CTX/.dev/handover.md" ]; then
    printf '=== .dev/handover.md ===\n'
    cat "$CTX/.dev/handover.md"
    printf '\n'
fi

printf '=== git log -3 ===\n'
git -C "$CTX" log -3 --decorate --oneline 2>/dev/null || true

exit 0
