#!/usr/bin/env bash
# scripts/run_remote_ubuntu.sh — drive build/test on the
# ubuntunote SSH host (native x86_64 Linux, real hardware).
#
# Replacement for the OrbStack `my-ubuntu-amd64` path
# (Rosetta-translated x86_64; tripped D-134 SIGSEGV race —
# closed per ADR-0067). Mirrors `run_remote_windows.sh`:
# `git fetch + reset --hard` the ubuntunote clone to the
# latest pushed `origin/zwasm-from-scratch`, then run the
# requested `zig build` step.
#
# Usage:
#   bash scripts/run_remote_ubuntu.sh                  # default: zig build test-all
#   bash scripts/run_remote_ubuntu.sh build            # zig build
#   bash scripts/run_remote_ubuntu.sh test             # zig build test
#   bash scripts/run_remote_ubuntu.sh test-spec        # zig build test-spec
#
# Prerequisites: SSH alias `ubuntunote` configured; Zig 0.16.0
# available remotely via the project's flake.nix dev shell;
# the repo cloned at ~/Documents/MyProducts/zwasm_from_scratch
# with `origin` pointing at clojurewasm/zwasm and the
# `zwasm-from-scratch` branch checked out. Setup procedure in
# `.dev/ubuntunote_setup.md`.
#
# Failure attribution: each remote step (preflight / sync /
# build) emits a labelled `[run_remote_ubuntu] FAIL: <step>`
# line on stderr before exiting, so the autonomous loop's log
# scan localises which phase broke without re-running.

set -euo pipefail
cd "$(dirname "$0")/.."

STEP="${1:-test-all}"
REMOTE_DIR="Documents/MyProducts/zwasm_from_scratch"
REMOTE_BRANCH="zwasm-from-scratch"

die_step() {
    echo "[run_remote_ubuntu] FAIL: $1" >&2
    exit 1
}

# 1. Preflight — clone exists, ssh + nix reachable. `bash -lc`
#    sources `/etc/profile.d/nix*.sh` (Determinate installer
#    injects the daemon profile there + into /etc/bash.bashrc),
#    so the remote `nix` command resolves from a non-interactive
#    SSH session without relying on user .bashrc.
echo "[run_remote_ubuntu] preflight (clone + nix reachable) ..."
ssh ubuntunote bash -lc "'
    test -d $REMOTE_DIR || exit 11
    command -v nix >/dev/null 2>&1 || exit 12
'" || {
    rc=$?
    case "$rc" in
        11) die_step "preflight — remote clone $REMOTE_DIR missing (see .dev/ubuntunote_setup.md)" ;;
        12) die_step "preflight — nix not in remote PATH (Determinate Nix install / profile missing)" ;;
        *)  die_step "preflight — ssh exit $rc (host unreachable, key auth, …)" ;;
    esac
}

# 2. Sync — fetch + reset + echo the landed SHA so logs record
#    what was actually tested. `git fetch` failure (network) vs
#    `reset --hard` failure (concurrent mod) are distinguished
#    by exit code below.
echo "[run_remote_ubuntu] sync ubuntunote:~/$REMOTE_DIR to origin/$REMOTE_BRANCH ..."
remote_sha="$(ssh ubuntunote bash -lc "'
    cd $REMOTE_DIR || exit 21
    git fetch origin $REMOTE_BRANCH >&2 || exit 22
    git checkout $REMOTE_BRANCH >&2 || exit 23
    git reset --hard origin/$REMOTE_BRANCH >&2 || exit 24
    git rev-parse --short HEAD
'")" || {
    rc=$?
    case "$rc" in
        21) die_step "sync — cd $REMOTE_DIR failed" ;;
        22) die_step "sync — git fetch origin failed (network / auth)" ;;
        23) die_step "sync — git checkout $REMOTE_BRANCH failed" ;;
        24) die_step "sync — git reset --hard origin/$REMOTE_BRANCH failed" ;;
        *)  die_step "sync — ssh exit $rc" ;;
    esac
}
echo "[run_remote_ubuntu] remote HEAD: $remote_sha"

# 3. Build / test. `build` is the implicit (default) step in
#    build.zig — invoking `zig build build` errors. Map the
#    human-friendly arg to no step.
if [ "$STEP" = "build" ]; then
    REMOTE_CMD="zig build"
else
    REMOTE_CMD="zig build $STEP"
fi

# `nix develop --command` pins Zig 0.16.0 + project deps via
# `flake.nix`, guaranteeing bit-identical toolchain with Mac
# and any other host.
echo "[run_remote_ubuntu] $REMOTE_CMD ..."
ssh ubuntunote bash -lc "'
    cd $REMOTE_DIR && nix develop --command bash -c \"$REMOTE_CMD\"
'" || die_step "build — '$REMOTE_CMD' failed on ubuntunote (HEAD=$remote_sha)"

echo "[run_remote_ubuntu] OK (HEAD=$remote_sha)."
