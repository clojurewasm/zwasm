#!/usr/bin/env bash
# scripts/ci_gate.sh — single source of truth for the HOST-LOCAL verification
# gate. Both CI (.github/workflows/ci.yml, once per matrix OS) and the local
# maintainer flow (gate_merge.sh mirrors these same steps) run this, so CI can
# never verify LESS than the per-host gate. It checks the CURRENT host only;
# multi-host fan-out is the caller's job (the CI matrix / gate_merge's SSH legs).
#
#   Core (every OS):  zig fmt --check + zig build test-all
#   Extended (ZWASM_CI_EXTENDED=1; Unix legs): lint + build-option DCE +
#     ReleaseSafe JIT smoke (D-245) + AOT cross-compile portability
#
# Usage:
#   bash scripts/ci_gate.sh                    # core gate on this host
#   ZWASM_CI_EXTENDED=1 bash scripts/ci_gate.sh   # + extended checks
set -euo pipefail
cd "$(dirname "$0")/.."

echo "[ci_gate] host: $(uname -s) — zig $(zig version)"

echo "[ci_gate] (1/2) zig fmt --check src/"
zig fmt --check src/

echo "[ci_gate] (2/2) zig build test-all"
zig build test-all

if [ "${ZWASM_CI_EXTENDED:-0}" = "1" ]; then
    echo "[ci_gate] extended: zig build lint"
    zig build lint

    echo "[ci_gate] extended: build-option DCE / level-separation (9 combos)"
    bash scripts/check_build_dce.sh --gate

    echo "[ci_gate] extended: --engine=jit ReleaseSafe smoke (D-245)"
    bash scripts/check_jit_releasesafe.sh

    echo "[ci_gate] extended: AOT cross-compile portability (§12.3)"
    bash scripts/check_aot_cross_compile.sh
fi

echo "[ci_gate] OK ($(uname -s))"
