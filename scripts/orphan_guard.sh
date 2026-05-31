#!/usr/bin/env bash
# scripts/orphan_guard.sh — sourced prelude for the backgrounded SSH
# gate launchers (run_remote_ubuntu.sh / run_remote_windows.sh).
#
# WHY (see .claude/rules/orphan_prevention.md): the /continue loop runs
# these gate scripts via `Bash(run_in_background: true)` and does NOT
# wait (ADR-0076 D2/D3 — the result is verified at the next cycle's
# Step 0.7). A parent-session kill (auto-compact, interrupt, overnight
# crash) re-parents the script + its `ssh <host>` child to PID 1; the
# next cycle then launches a fresh one, stacking SSH transports. On
# this Mac that pile compounds with Microsoft Defender's continuous
# scan of .zig-cache / zig-out build artifacts (wdavdaemon at ~20% CPU
# even idle) — the same Defender real-time-scan interference already
# root-caused on windowsmini (debt D-028 hyp #5) — driving host load up
# (fan events, garbled tool channel). The global cleanup_orphans.sh
# backstop only reaps at etime > 30 min, far too coarse for a 3-5 min
# gate, so this is the intra-session guard.
#
# orphan_guard makes "one remote gate at a time, self-bounded" STRUCTURAL
# without changing how the loop invokes the scripts:
#   1. Reap any PRIOR instance of the calling script (other PID).
#   2. Reap `ssh <host>` clients orphaned to PID 1 (precise: ppid==1 —
#      a live gate's own ssh child and interactive ssh are untouched).
#   3. Re-exec the caller under `timeout` so a parent-kill leaves no
#      forever-orphan. The caller's SSH keepalive opts let the remote
#      sshd drop the remote build when the local client dies (the
#      "timeout does NOT propagate to the remote" caveat — see rule).
#
# Usage (before `set -euo pipefail`, before any work):
#   _og="$(dirname "$0")/orphan_guard.sh"
#   [ -f "$_og" ] && source "$_og" && orphan_guard "$0" <ssh-host> "$@"
#
# Override the bound: REMOTE_GATE_TIMEOUT=3600 bash scripts/run_remote_*.sh

orphan_guard() {
    # Idempotent: the re-exec'd child inherits _REMOTE_GUARDED and skips
    # straight through to the caller's real work.
    [ -n "${_REMOTE_GUARDED:-}" ] && return 0

    local self_path="$1" host="$2"
    shift 2
    local base self_pid pid ppid to
    base="$(basename "$self_path")"
    self_pid=$$

    # 1. Reap a prior instance of this exact script (stacking guard —
    #    the loop never legitimately runs two at once per ADR-0076).
    for pid in $(pgrep -f "$base" 2>/dev/null || true); do
        [ "$pid" = "$self_pid" ] && continue
        kill -TERM "$pid" 2>/dev/null || true
        echo "[orphan_guard] reaped prior $base ($pid)" >&2
    done

    # 2. Reap `ssh <host>` clients orphaned to PID 1 only.
    for pid in $(pgrep -f "ssh $host" 2>/dev/null || true); do
        ppid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
        [ "$ppid" = "1" ] || continue
        kill -TERM "$pid" 2>/dev/null || true
        echo "[orphan_guard] reaped orphan 'ssh $host' ($pid, ppid 1)" >&2
    done

    # 3. Re-exec self under a total time bound. Degrade gracefully if no
    #    timeout binary is on PATH (the reap already ran; run unbounded).
    export _REMOTE_GUARDED=1
    if command -v timeout >/dev/null 2>&1; then
        to=timeout
    elif command -v gtimeout >/dev/null 2>&1; then
        to=gtimeout
    else
        echo "[orphan_guard] no timeout binary on PATH; running unbounded" >&2
        return 0
    fi
    exec "$to" "${REMOTE_GATE_TIMEOUT:-1800}" bash "$self_path" "$@"
}
