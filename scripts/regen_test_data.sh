#!/usr/bin/env bash
# scripts/regen_test_data.sh — regenerate all derivative test data.
#
# Single uniform recipe across Mac / OrbStack Ubuntu / windowsmini
# (ROADMAP §11.2). Source-of-truth (.wat / .wast / C / Rust / Go
# sources) lives in git; this script produces the gitignored
# derivatives.
#
# Phase 0: stub.
# Phase 1+: wast2json over committed .wast files → test/spec/json/
# Phase 4+: build realworld samples from C / Rust / Go sources.
# Phase 5+: regenerate fuzz corpus via wasm-tools smith.

set -euo pipefail
cd "$(dirname "$0")/.."

echo "[regen_test_data] Phase 0 stub. Phase 1+ wires wast2json + toolchain builds."
echo "[regen_test_data] Sources of truth (committed):"
echo "                   test/spec/wat/      (Phase 1+)"
echo "                   test/spec/wast/     (Phase 1+)"
echo "                   test/realworld/src/ (Phase 4+)"
echo "                   bench/runners/src/  (Phase 10+)"

# Phase 1+: when test/spec/wast/ exists, fan out wast2json.
# Phase 4+: build realworld samples.
# Phase 10+: build bench wasms.
