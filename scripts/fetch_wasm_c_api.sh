#!/usr/bin/env bash
# scripts/fetch_wasm_c_api.sh — vendor `include/wasm.h` from the
# upstream WebAssembly/wasm-c-api repository at a pinned commit.
#
# Phase 3 / §9.3 / 3.0: this script is the single source of truth
# for which upstream commit's `wasm.h` we ship. The pinned commit
# hash also appears in ADR-0004; if you change one, change the
# other and reference the ADR in the commit message per §18.
#
# Usage:
#   bash scripts/fetch_wasm_c_api.sh              # vendor + verify
#   WASM_C_API_PIN=<sha> bash scripts/fetch_wasm_c_api.sh
#                                                 # rare: pin bump
#
# Env overrides:
#   WASM_C_API_REPO  path to a local clone (default: try
#                    ~/Documents/OSS/wasm-c-api/, fall back to
#                    cloning into a temp dir)
#   WASM_C_API_PIN   override the pinned commit (rare; usually
#                    only when bumping the pin in tandem with the
#                    ADR + this script)

set -euo pipefail
cd "$(dirname "$0")/.."

# -----------------------------------------------------------------------------
# Pinned upstream commit. Bumping this requires:
#   1. Update WASM_C_API_PIN_DEFAULT below.
#   2. Update `.dev/decisions/0004_phase3_wasm_c_api_pin.md` to
#      reference the new hash + summarise upstream changes.
#   3. Re-run this script; commit `include/wasm.h` + the ADR
#      bump together with `chore(p3): bump wasm-c-api pin to <h>
#      (ADR-0004)`.
# -----------------------------------------------------------------------------
WASM_C_API_PIN_DEFAULT=9d6b93764ac96cdd9db51081c363e09d2d488b4d
WASM_C_API_PIN=${WASM_C_API_PIN:-$WASM_C_API_PIN_DEFAULT}

DEST_HEADER=include/wasm.h

# Resolve a usable upstream tree: prefer the local reference clone
# (faster and offline-friendly), fall back to a fresh shallow
# clone in a temp dir.
LOCAL_DEFAULT="$HOME/Documents/OSS/wasm-c-api"
REPO=${WASM_C_API_REPO:-$LOCAL_DEFAULT}

CLEANUP_TMP=
if [ ! -d "$REPO/.git" ]; then
  echo "[fetch_wasm_c_api] no local clone at $REPO; cloning to a temp dir" >&2
  CLEANUP_TMP=$(mktemp -d)
  trap 'rm -rf "$CLEANUP_TMP"' EXIT
  git clone --quiet https://github.com/WebAssembly/wasm-c-api.git "$CLEANUP_TMP/wasm-c-api"
  REPO="$CLEANUP_TMP/wasm-c-api"
fi

# Verify the pinned commit exists in the resolved tree, fetching
# if needed.
if ! git -C "$REPO" cat-file -e "$WASM_C_API_PIN" 2>/dev/null; then
  echo "[fetch_wasm_c_api] pin $WASM_C_API_PIN not in $REPO; fetching" >&2
  git -C "$REPO" fetch --quiet origin "$WASM_C_API_PIN" 2>/dev/null || \
    git -C "$REPO" fetch --quiet origin
  if ! git -C "$REPO" cat-file -e "$WASM_C_API_PIN" 2>/dev/null; then
    echo "[fetch_wasm_c_api] pin $WASM_C_API_PIN still missing after fetch" >&2
    exit 1
  fi
fi

mkdir -p "$(dirname "$DEST_HEADER")"
git -C "$REPO" show "$WASM_C_API_PIN:include/wasm.h" > "$DEST_HEADER"

# Sanity: the file must be non-empty and contain the upstream
# include guard. If upstream restructures, this script + the ADR
# need updating in lockstep.
if [ ! -s "$DEST_HEADER" ]; then
  echo "[fetch_wasm_c_api] $DEST_HEADER is empty after extract" >&2
  exit 1
fi
if ! grep -q "WASM_H" "$DEST_HEADER"; then
  echo "[fetch_wasm_c_api] $DEST_HEADER does not look like wasm.h" >&2
  exit 1
fi

echo "[fetch_wasm_c_api] $DEST_HEADER vendored at pin $WASM_C_API_PIN"
