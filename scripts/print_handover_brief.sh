#!/usr/bin/env bash
# scripts/print_handover_brief.sh — emit the resume brief that
# SessionStart and PostCompact hooks inject into Claude's context.
#
# Since #207 plank 4 (2026-08-20): current state lives in open PRs and
# issues, not in .dev/handover.md (frozen — a campaign-era record). The
# brief is live GitHub state plus recent commits:
#   - open PRs (number, draft flag, title, branch)
#   - open issues (number, title)
#   - last 3 git commits (oneline + decorate)
#
# The GitHub sections need the `gh` CLI; when gh is absent, offline, or
# unauthenticated, a one-line notice replaces them. Every gh call is
# time-bounded so a stalled network cannot delay session start. Stdout
# is the brief; exits 0 always — the hook must never block a session.

set -u

CTX="${CLAUDE_PROJECT_DIR:-$(dirname "$0")/..}"

# Bound a command at 10 s where a timeout binary exists (GNU coreutils,
# or gtimeout from brew coreutils on Mac); run unbounded otherwise.
bounded() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 10 "$@"
    elif command -v gtimeout >/dev/null 2>&1; then
        gtimeout 10 "$@"
    else
        "$@"
    fi
}

if command -v gh >/dev/null 2>&1 &&
   prs="$(cd "$CTX" && bounded gh pr list --state open \
       --json number,title,headRefName,isDraft \
       --jq '.[] | "#\(.number)\(if .isDraft then " [draft]" else "" end) \(.title) (\(.headRefName))"' \
       2>/dev/null)" &&
   issues="$(cd "$CTX" && bounded gh issue list --state open \
       --json number,title \
       --jq '.[] | "#\(.number) \(.title)"' \
       2>/dev/null)"; then
    printf '=== open PRs ===\n%s\n\n' "${prs:-(none)}"
    printf '=== open issues ===\n%s\n\n' "${issues:-(none)}"
else
    printf '(gh unavailable or offline — open PRs/issues not shown; see https://github.com/zwasm/zwasm)\n\n'
fi

printf '=== git log -3 ===\n'
git -C "$CTX" log -3 --decorate --oneline 2>/dev/null || true
printf '\n'

exit 0
