#!/usr/bin/env bash
# Vendor the official wasi-testsuite wasm32-wasip3 conformance binaries
# (ADR-0205 D3) into test/component/wasip3_official/.
#
# Source of truth: the `prod/testsuite-base` branch of
# https://github.com/WebAssembly/wasi-testsuite — the upstream-built binaries
# for the tests under tests/rust/wasm32-wasip3/ (Apache-2.0; see
# legal/THIRD_PARTY.md). Binaries are `wasm-tools strip`ped (drops the ~2.5 MB
# of debug custom sections per binary; behavior-identical) before committing.
# Manifests (.json) come from the same pinned commit's `main`-side sources.
#
# Deliberate-bump-only (ADR-0205 D6): edit PIN_SHA + re-run + commit.
set -euo pipefail

PIN_SHA="988bf8cfdca146517f917a1ed9160a4a48d3f767" # prod/testsuite-base 2026-08-10
CLONE="${WASI_TESTSUITE_CLONE:-$HOME/Documents/OSS/wasi-testsuite}"
DEST="$(cd "$(dirname "$0")/.." && pwd)/test/component/wasip3_official"

# Staged enablement (ADR-0205 D4): extend per phase as host surfaces land.
TESTS=(
  # phase A — cli / clocks / random / run
  cli-env cli-exit cli-stdio cli-stdio-roundtrip cli-stdout-flush cli-terminal
  monotonic-clock multi-clock-wait random wall-clock run-with-err
)

command -v wasm-tools >/dev/null || { echo "wasm-tools required" >&2; exit 1; }
git -C "$CLONE" rev-parse --quiet --verify "$PIN_SHA^{commit}" >/dev/null || {
  echo "pin $PIN_SHA not present in $CLONE — fetch prod/testsuite-base first:" >&2
  echo "  git -C $CLONE fetch origin prod/testsuite-base" >&2
  exit 1
}

mkdir -p "$DEST"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

for t in "${TESTS[@]}"; do
  git -C "$CLONE" show "$PIN_SHA:tests/rust/testsuite/wasm32-wasip3/$t.wasm" > "$tmp/$t.wasm"
  wasm-tools strip "$tmp/$t.wasm" -o "$DEST/$t.wasm"
  # Manifest is optional upstream (absent = run + expect exit 0).
  if git -C "$CLONE" cat-file -e "$PIN_SHA:tests/rust/wasm32-wasip3/src/bin/$t.json" 2>/dev/null; then
    git -C "$CLONE" show "$PIN_SHA:tests/rust/wasm32-wasip3/src/bin/$t.json" > "$DEST/$t.json"
  fi
done

echo "vendored ${#TESTS[@]} tests at pin $PIN_SHA into $DEST"
