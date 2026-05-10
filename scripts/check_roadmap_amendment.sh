#!/usr/bin/env bash
# scripts/check_roadmap_amendment.sh — PreToolUse reminder hook.
#
# Fires before every Edit/Write call. When the target is
# `.dev/ROADMAP.md`, injects a `§18` reminder via
# `hookSpecificOutput.additionalContext` so the agent re-anchors on
# the amendment policy at the moment of editing — not just at
# session start. This complements the cold-start /
# PostCompact brief (`scripts/print_handover_brief.sh`).
#
# Always exits 0 and never blocks the tool call. If `jq` is
# missing or the JSON malformed, the hook is a silent no-op.

set -u

INPUT="$(cat 2>/dev/null || true)"

if ! command -v jq >/dev/null 2>&1; then
    exit 0
fi

FILE_PATH="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)"

case "$FILE_PATH" in
    */.dev/ROADMAP.md|.dev/ROADMAP.md|*/ROADMAP.md)
        ;;
    *)
        exit 0
        ;;
esac

MSG=$(cat <<'EOF'
§18 reminder: editing ROADMAP. Decide before saving:

- Routine update (§18.3a) — `[ ]` → `[x]` where row scope text
  is unchanged; SHA backfill on `[x]` row; Phase Status widget
  advance; one-time inline-expansion of the NEXT phase's task
  table when it opens; pointing a row at an existing
  `phase_log/<phase>.md` entry. Proceed; no ADR needed.
- Load-bearing change (§18.3) — scope or exit-criterion edits
  in §1, §2 (P/A), §4 (Zone / ZirOp / architecture), §5 (file
  layout), §9 phase rows (scope / exit), §11 layers, §14
  forbidden list. STOP. File `.dev/decisions/NNNN_<slug>.md`
  FIRST per §18.2, reference its number in the commit message,
  then edit.
- Forbidden (§18.3) — accumulating sub-chunk prose into a §9
  row description or status cell. Sub-chunk records belong in
  commit messages + `.dev/phase_log/<phase>.md`.

If unsure which bucket this edit falls in, ask the user before
proceeding.
EOF
)

jq -n --arg msg "$MSG" '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $msg}}'
exit 0
