#!/usr/bin/env bash
# scripts/ci_gate.sh — single source of truth for the HOST-LOCAL verification
# gate. Both CI (.github/workflows/ci.yml, once per matrix OS) and the local
# maintainer flow (gate_merge.sh mirrors these same steps) run this, so CI can
# never verify LESS than the per-host gate. It checks the CURRENT host only;
# multi-host fan-out is the caller's job (the CI matrix / gate_merge's SSH legs).
#
#   Core (every OS):  zig fmt --check + zig build test-all
#   Extended (ZWASM_CI_EXTENDED=1; Unix legs): lint + build-option DCE +
#     ReleaseSafe JIT smoke (D-245) + AOT cross-compile portability +
#     zone_check + spill_aware_check (host-independent source checks,
#     promoted to CI 2026-07-03 as real merge gates)
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

# rust-host embedding consumer (D-254): the third independent embedding-ABI
# consumer (docs/examples/rust_host/hello.rs links the same libzwasm.a the C
# host uses) — exercise it so it can't rot silently. LINUX-only: the ubuntu
# runner ships a gnu-target rustc that is ABI-compatible with zig's native
# libzwasm.a, so the link is clean (the macOS SDK dance + the Windows rust ABI
# question are out of scope here). Runs on EVERY PR (core), so a break shows on
# the PR's Linux leg before merge, not post-merge. Skips gracefully where rustc
# is absent (e.g. a local gate host without the .#rust-host shell).
if [ "$(uname -s)" = "Linux" ]; then
    if command -v rustc >/dev/null 2>&1; then
        echo "[ci_gate] rust-host embedding consumer (zig build run-rust-host, D-254)"
        zig build run-rust-host
    else
        echo "[ci_gate] (skip run-rust-host — rustc not on PATH; needs the .#rust-host shell)"
    fi
fi

if [ "${ZWASM_CI_EXTENDED:-0}" = "1" ]; then
    echo "[ci_gate] extended: zig build lint"
    zig build lint

    echo "[ci_gate] extended: build-option DCE / level-separation (9 combos)"
    bash scripts/check_build_dce.sh --gate

    echo "[ci_gate] extended: --engine=jit ReleaseSafe smoke (D-245)"
    bash scripts/check_jit_releasesafe.sh

    echo "[ci_gate] extended: AOT cross-compile portability (§12.3)"
    bash scripts/check_aot_cross_compile.sh

    # Host-independent source checks (promoted to CI 2026-07-03 per the
    # scaffolding-decisions batch). They walk src/ only, so the Unix extended
    # leg is a fine home; zone_check is now a real merge gate via ci-required.
    echo "[ci_gate] extended: zone dependency check (zone_check --gate)"
    bash scripts/zone_check.sh --gate

    # spill_aware_check promotion is HELD (D-505): it was never wired into
    # gate_commit, so 7 pre-existing violations accumulated in arm64 SIMD
    # handlers. Promote here only AFTER those are triaged (fix-or-EXEMPT).
    # echo "[ci_gate] extended: spill-aware op-handler check (spill_aware_check --gate)"
    # bash scripts/spill_aware_check.sh --gate
fi

echo "[ci_gate] OK ($(uname -s))"
