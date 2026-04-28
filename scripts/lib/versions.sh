#!/usr/bin/env bash
# scripts/lib/versions.sh — sourceable bash loader for .github/versions.lock.
#
# Usage from another script:
#
#     source "$(dirname "$0")/lib/versions.sh"
#     echo "$ZIG_VERSION"
#
# The loader exports every KEY=value pair found in .github/versions.lock.
# Comments (entire-line `#` lines) and blank lines are ignored. Inline
# comments after a value are NOT supported in versions.lock by policy
# (see the file header) — bash's own `source` would already strip them,
# but the Python reader in ci.yml does not, so we keep the file simple.

set -euo pipefail

_zwasm_repo_root() {
    # Walk up from this file to find the repo root (the directory holding
    # .github/versions.lock).
    local dir
    dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    while [ "$dir" != "/" ] && [ ! -f "$dir/.github/versions.lock" ]; do
        dir="$(dirname "$dir")"
    done
    if [ ! -f "$dir/.github/versions.lock" ]; then
        echo "versions.sh: cannot locate .github/versions.lock from ${BASH_SOURCE[0]}" >&2
        return 1
    fi
    printf '%s' "$dir"
}

ZWASM_REPO_ROOT="$(_zwasm_repo_root)"
export ZWASM_REPO_ROOT

# `set -a` makes every subsequent assignment automatically exported, which
# is what we want for the lock file's `KEY=value` lines. Bash skips comment
# and blank lines when sourcing.
set -a
# shellcheck disable=SC1091
source "$ZWASM_REPO_ROOT/.github/versions.lock"
set +a

# Sanity: at least the [enforced] pins must be set. Catches typos in the
# lock file or accidental removal early.
: "${ZIG_VERSION:?ZIG_VERSION not set in versions.lock}"
: "${WASM_TOOLS_VERSION:?WASM_TOOLS_VERSION not set in versions.lock}"
: "${WASMTIME_VERSION:?WASMTIME_VERSION not set in versions.lock}"
: "${WASI_SDK_VERSION:?WASI_SDK_VERSION not set in versions.lock}"
: "${RUST_VERSION:?RUST_VERSION not set in versions.lock}"
