#!/usr/bin/env bash
# scripts/run_remote_windows.sh — drive build/test on the windowsmini SSH host.
#
# `git fetch + reset --hard` the windowsmini clone to the latest
# pushed `origin/main`, then run the requested
# `zig build` step there. Phase 15+ may extend this with a
# `git bundle` path so unpushed commits can also be exercised; for
# now we test the latest pushed state, mirroring zwasm v1.
#
# Usage:
#   bash scripts/run_remote_windows.sh                         # default: zig build test-all on main
#   bash scripts/run_remote_windows.sh build                   # zig build
#   bash scripts/run_remote_windows.sh test                    # zig build test
#   bash scripts/run_remote_windows.sh test-spec               # zig build test-spec
#   bash scripts/run_remote_windows.sh --branch NAME [STEP]    # test arbitrary branch (feature-branch verification)
#
# The `--branch` form mirrors run_remote_ubuntu.sh and is used
# by §9.13-V Phase A.6 to verify feature branches (e.g.
# `develop/value16`) before merging to the trunk
# (`main`).
#
# Prerequisites: SSH alias `windowsmini` configured; Zig 0.16.0
# installed remotely; the repo cloned at
# ~/Documents/MyProducts/zwasm (see
# `.dev/windows_ssh_setup.md`).

# Orphan guard — reap prior orphans + self-bound under timeout before
# any work (see scripts/orphan_guard.sh + orphan_prevention.md). Must
# run before `set -e` so the reap's empty-pgrep exits don't abort. A
# wedged windows test-all (debt D-028 >120 min) is exactly what the
# bound + next-launch reap defeat; override with REMOTE_GATE_TIMEOUT.
# Per-machine host config FIRST (see dev_hosts.env.example) — resolved
# via an absolute script dir so any invocation cwd works, and before the
# orphan guard so the guard reaps SSH clients of the CONFIGURED host.
_sd="$(cd "$(dirname "$0")" && pwd)"
[ -f "$_sd/dev_hosts.env" ] && source "$_sd/dev_hosts.env"

_og="$_sd/orphan_guard.sh"
[ -f "$_og" ] && source "$_og" && orphan_guard "$0" "${ZWASM_WINDOWS_HOST:-windowsmini}" "$@"

set -euo pipefail
cd "$_sd/.."

# SSH keepalive: a dead local client makes the remote sshd drop the
# channel — and the remote `zig build` — within ~2 min (the "timeout
# does NOT propagate" caveat; especially load-bearing on windowsmini
# where Defender scan stalls have wedged runs — D-028).
SSH_OPTS="-o ServerAliveInterval=30 -o ServerAliveCountMax=4"

# Maintainer SSH gate — the Windows x86_64 host and its clone path are
# env-configurable (defaults are the project maintainer's hosts). Point
# ZWASM_WINDOWS_HOST at your own SSH alias, or set it once in the
# per-machine scripts/dev_hosts.env (sourced above).
HOST="${ZWASM_WINDOWS_HOST:-windowsmini}"
REMOTE_DIR="${ZWASM_REMOTE_DIR:-Documents/MyProducts/zwasm}"
REMOTE_BRANCH="main"
if [ "${1:-}" = "--branch" ]; then
    if [ -z "${2:-}" ]; then
        echo "[run_remote_windows] FAIL: --branch requires a branch name" >&2
        exit 2
    fi
    REMOTE_BRANCH="$2"
    shift 2
fi
STEP="${1:-test-all}"

echo "[run_remote_windows] sync $HOST:~/$REMOTE_DIR to origin/$REMOTE_BRANCH ..."
if ! ssh $SSH_OPTS "$HOST" bash -lc "'cd $REMOTE_DIR && git fetch origin $REMOTE_BRANCH && git checkout $REMOTE_BRANCH && git reset --hard origin/$REMOTE_BRANCH'"; then
    echo "[run_remote_windows] FAIL: sync — could not reach/sync '$HOST'. NOTE: this local fan-out is OPTIONAL (CI runs the 3-OS gate on every PR); to use your own host, configure scripts/dev_hosts.env (see dev_hosts.env.example)" >&2
    exit 1
fi

# `build` is the implicit (default) step in build.zig — invoking
# `zig build build` errors. Map the human-friendly arg to no step.
if [ "$STEP" = "build" ]; then
    REMOTE_CMD="zig build"
else
    REMOTE_CMD="zig build $STEP"
fi

echo "[run_remote_windows] $REMOTE_CMD ..."
ssh $SSH_OPTS "$HOST" bash -lc "'cd $REMOTE_DIR && $REMOTE_CMD'"

echo "[run_remote_windows] OK."
