#!/usr/bin/env bash
# scripts/regen_test_data.sh — regenerate derivative test data.
#
# Phase 1: bake the curated Wasm-1.0 (MVP) corpus into
#   test/spec/wasm-1.0/<name>.0.wasm via wast2json (from wabt in the
#   dev shell). Pin and curation list live in
#   test/spec/wasm-1.0/README.md per ADR-0002.
#
# Phase 4+: build realworld samples from C / Rust / Go sources.
# Phase 11+: build bench wasms.

set -euo pipefail
cd "$(dirname "$0")/.."

UPSTREAM=${WASM_SPEC_REPO:-$HOME/Documents/OSS/WebAssembly/spec}
DEST=test/spec/wasm-1.0
TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

if ! command -v wast2json >/dev/null 2>&1; then
  echo "[regen_test_data] wast2json not found (need wabt in PATH or dev shell)" >&2
  exit 1
fi

if [ ! -d "$UPSTREAM/test/core" ]; then
  echo "[regen_test_data] upstream not found at $UPSTREAM/test/core" >&2
  echo "[regen_test_data] set WASM_SPEC_REPO env var to override" >&2
  exit 1
fi

NAMES=(const forward labels local_get local_set nop switch unreachable unwind)

for n in "${NAMES[@]}"; do
  src="$UPSTREAM/test/core/$n.wast"
  if [ ! -f "$src" ]; then
    echo "[regen_test_data] missing $src" >&2
    exit 1
  fi
  ( cd "$TMP" && wast2json "$src" -o "$n.json" >/dev/null 2>&1 )
  cp "$TMP/$n.0.wasm" "$DEST/"
done

echo "[regen_test_data] regenerated ${#NAMES[@]} fixtures into $DEST/"
