#!/usr/bin/env bash
# Survey-budget guard — mechanical enforcement of the "fork Step-0
# surveys to an Explore subagent" discipline (textbook_survey.md;
# lesson 2026-05-31-continue-context-burn-survey-in-main).
#
# Wired as a PreToolUse hook on Read|Grep|Bash|Task|Agent and a
# UserPromptSubmit hook. It counts MAIN-CONTEXT survey operations
# (Read / Grep / survey-like Bash) per turn and:
#   - SOFT (advisory, stdout, non-blocking): "you're surveying in
#     main; consider forking to an Explore subagent".
#   - HARD (exit 2, blocks the tool, feeds the reason to the model):
#     forces a pause so the remaining survey gets forked.
# The counter RESETS to 0 on a new user message (UserPromptSubmit)
# and on any subagent dispatch (Task / Agent) — i.e. forking the
# survey clears the budget. So the guard is self-healing: comply
# (dispatch a subagent) and it gets out of the way.
#
# Why a hook and not just prose: the prose rule already existed and
# was not followed (the survey ran in main and burned ~83% of the
# 200K window in ~10 min). This makes the discipline mechanical.

set -euo pipefail

SOFT="${SURVEY_BUDGET_SOFT:-7}"
HARD="${SURVEY_BUDGET_HARD:-12}"

payload="$(cat)"

# Robust field extraction (python3 is already a hook dependency here).
read -r EVENT TOOL SESSION CMD <<EOF
$(python3 - "$payload" <<'PY'
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    print("? ? ? ?"); raise SystemExit
ev = d.get("hook_event_name", "?")
tool = d.get("tool_name", "?")
sess = d.get("session_id", "default")
cmd = (d.get("tool_input", {}) or {}).get("command", "")
# Collapse command to a single whitespace-free-ish token bag for grep.
cmd = " ".join(cmd.split())[:400] if isinstance(cmd, str) else ""
# Encode cmd presence of survey verbs as a flag to avoid quoting pain.
import re
survey = bool(re.search(r'\b(grep|rg|sed|cat|head|tail|find|awk|less)\b', cmd))
print(ev, tool, sess, "SURVEYCMD" if survey else "OTHERCMD")
PY
)
EOF

state_dir="${CLAUDE_PROJECT_DIR:-.}/private"
mkdir -p "$state_dir" 2>/dev/null || true
state_file="$state_dir/.survey_budget_${SESSION}"

# Reset signals: new user turn, or a subagent dispatch (survey forked).
case "$EVENT" in
  UserPromptSubmit) echo 0 > "$state_file" 2>/dev/null || true; exit 0 ;;
esac
case "$TOOL" in
  Task|Agent) echo 0 > "$state_file" 2>/dev/null || true; exit 0 ;;
esac

# Count only main-context survey operations.
is_survey=0
case "$TOOL" in
  Read|Grep) is_survey=1 ;;
  Bash) [ "$CMD" = "SURVEYCMD" ] && is_survey=1 ;;
esac
[ "$is_survey" -eq 1 ] || exit 0

count=0
[ -f "$state_file" ] && count="$(cat "$state_file" 2>/dev/null || echo 0)"
count=$((count + 1))
echo "$count" > "$state_file" 2>/dev/null || true

if [ "$count" -ge "$HARD" ]; then
  # exit 2 → tool blocked, stderr fed back to the model as the reason.
  echo "🛑 Survey-budget guard: ${count} main-context survey ops this turn (Read/Grep/grep-Bash) without forking. Per textbook_survey.md + lesson 2026-05-31-continue-context-burn-survey-in-main, Step-0 surveys MUST be forked to an Explore subagent (Agent tool, subagent_type 'Explore'). Dispatch a subagent for the remaining file reads — that resets this budget. (Override: SURVEY_BUDGET_HARD env.)" >&2
  exit 2
fi

if [ "$count" -ge "$SOFT" ]; then
  echo "[survey-budget] ${count} main-context survey ops this turn — consider forking the rest to an Explore subagent (textbook_survey.md). Hard stop at ${HARD}."
fi

exit 0
