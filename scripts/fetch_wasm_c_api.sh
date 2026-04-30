#!/usr/bin/env bash
# Fetch include/wasm.h from upstream WebAssembly/wasm-c-api at a pinned commit.
# The pinned hash is recorded by an ADR when wasm.h is first introduced
# (Phase 3 per ROADMAP §9). Bumping it requires a new ADR.

set -euo pipefail
cd "$(dirname "$0")/.."

UPSTREAM="https://raw.githubusercontent.com/WebAssembly/wasm-c-api"
PINNED_COMMIT="${WASM_C_API_PIN:-main}"   # ADR records the actual SHA

echo "[fetch_wasm_c_api] fetching wasm.h at $PINNED_COMMIT ..."
curl -fsSL "$UPSTREAM/$PINNED_COMMIT/include/wasm.h" -o include/wasm.h.upstream

if ! cmp -s include/wasm.h include/wasm.h.upstream 2>/dev/null; then
    echo "[fetch_wasm_c_api] include/wasm.h changed — review the diff:"
    diff -u include/wasm.h include/wasm.h.upstream || true
    echo
    echo "[fetch_wasm_c_api] If the change is intentional, run:"
    echo "    mv include/wasm.h.upstream include/wasm.h"
    echo "    # and update the ADR pinning the commit hash."
    exit 1
fi

rm -f include/wasm.h.upstream
echo "[fetch_wasm_c_api] include/wasm.h matches pinned upstream — OK."
