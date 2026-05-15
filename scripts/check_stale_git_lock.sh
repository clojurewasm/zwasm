#!/usr/bin/env bash
# Stale .git/index.lock sweeper — invoked as PreToolUse hook by Claude Code
# before any Bash invocation. Reads the JSON payload from stdin, peeks at
# the embedded `command`, and removes `.git/index.lock` iff it has been
# untouched for > LOCK_STALE_SECS seconds.
#
# Why: git commit's pre-commit gate (gate_commit.sh runs zig build test +
# zone_check + file_size_check + spill_aware_check + lint) holds the lock
# for minutes. Concurrent git operations from editor integrations, MCP
# tooling, or the autonomous /continue loop's own parallel Bash calls
# can crash mid-acquire, leaving a 0-byte stale lock behind. Removing
# anything that's both (a) older than LOCK_STALE_SECS, AND (b) checked
# only when the next tool use is a git command, is safe — a live lock
# would be touched within seconds by the holding process.
#
# Always exits 0 (never blocks the tool). The sweep is silent on no-op;
# noisy only when it actually removed a stale lock.

set -uo pipefail

LOCK_STALE_SECS=60

input=$(cat)

# Only fire on git or gh commands. Everything else is a no-op.
case "$input" in
    *'"git '*|*'"gh '*) ;;
    *) exit 0 ;;
esac

REPO=${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || echo .)}
LOCK="$REPO/.git/index.lock"
[ -e "$LOCK" ] || exit 0

# Portable mtime: BSD `stat -f %m` (macOS) vs GNU `stat -c %Y` (Linux).
if mtime=$(stat -f %m "$LOCK" 2>/dev/null); then
    :
elif mtime=$(stat -c %Y "$LOCK" 2>/dev/null); then
    :
else
    # Can't read mtime → don't risk removal.
    exit 0
fi

now=$(date +%s)
age=$((now - mtime))
if [ "$age" -gt "$LOCK_STALE_SECS" ]; then
    rm -f "$LOCK"
    echo "check_stale_git_lock: removed stale .git/index.lock (age ${age}s)" >&2
fi

exit 0
