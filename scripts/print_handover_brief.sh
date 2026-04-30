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

cat <<'EOF'
=== ROADMAP §18 / ADR re-anchor ===
Editing .dev/ROADMAP.md? A PreToolUse hook re-prints this rule at the moment of edit; remember it now too:
- Routine status update ([ ]->[x], expanding the next phase table inline, backfilling SHA pointers, advancing the Phase Status widget) — proceed.
- Deviation from §1, §2 (P/A), §4 (architecture / Zone / ZirOp), §5 (layout), §9 phase scope/exit, §11 layers, §14 forbidden list — file .dev/decisions/NNNN_<slug>.md FIRST per §18, reference it in the commit, then edit.
- "Quiet" edits to load-bearing sections are forbidden (§18.3). If unsure, ask the user.

EOF

if [ -f "$CTX/.dev/handover.md" ]; then
    printf '=== .dev/handover.md ===\n'
    cat "$CTX/.dev/handover.md"
    printf '\n'
fi

printf '=== git log -3 ===\n'
git -C "$CTX" log -3 --decorate --oneline 2>/dev/null || true

exit 0
