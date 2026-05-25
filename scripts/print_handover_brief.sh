#!/usr/bin/env bash
# scripts/print_handover_brief.sh — emit the resume brief that
# SessionStart and PostCompact hooks inject into Claude's context.
#
# Per ADR-0118 D5: this script now emits ONLY dynamic state.
# Frozen reminders (language policy, /continue literal=60, ROADMAP §18
# anchor) live in CLAUDE.md "Frozen loop invariants" section — read
# once per cold-start. This avoids ~50 lines of recurring tokens at
# every SessionStart + PostCompact.
#
# Dynamic state emitted:
#   - .dev/handover.md body
#   - last 3 git commits (oneline + decorate)
#   - ubuntu.log verdict (Step 0.7 anchor)
#   - bundle-active status (per ADR-0118 D6)
#
# Stdout is the brief; stderr suppressed. Exits 0 even on failure —
# the hook should never block the agent.

set -u

CTX="${CLAUDE_PROJECT_DIR:-$(dirname "$0")/..}"

if [ -f "$CTX/.dev/handover.md" ]; then
    printf '=== .dev/handover.md ===\n'
    cat "$CTX/.dev/handover.md"
    printf '\n'
fi

printf '=== git log -3 ===\n'
git -C "$CTX" log -3 --decorate --oneline 2>/dev/null || true
printf '\n'

# Bundle-active state (per ADR-0118 D6).
if [ -x "$CTX/scripts/check_bundle_active.sh" ]; then
    printf '=== bundle status ===\n'
    bash "$CTX/scripts/check_bundle_active.sh" 2>&1 | head -3 || true
    printf '\n'
fi

# Prior-cycle ubuntu verdict (Step 0.7 anchor).
if [ -f /tmp/ubuntu.log ]; then
    printf '=== /tmp/ubuntu.log tail ===\n'
    tail -3 /tmp/ubuntu.log 2>/dev/null || true
    printf '\n'
fi

exit 0
