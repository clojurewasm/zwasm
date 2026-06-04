#!/usr/bin/env bash
# D-245 regression gate — host→JIT calls must preserve the host's callee-saved
# registers. The bug ONLY manifests in ReleaseSafe (the optimized host keeps
# live values in the callee-saved regs the JIT clobbers); the Debug-only
# `runWasmJit` unit test missed it, so it shipped. A build.zig run-artifact
# can't catch it because an exe's optimize mode does NOT propagate to imported
# modules (the `core` lib keeps its own -Doptimize), so the only faithful check
# is a full `-Doptimize=ReleaseSafe` build + run.
#
# Build ReleaseSafe + run a SIMD `_start` via `--engine=jit` (the interp has no
# SIMD, so this forces the JIT execute path). A non-zero exit = the
# callee-saved-clobber SEGV regressed. Cheap to read, ~minutes to build.
set -euo pipefail
cd "$(dirname "$0")/.."

FIXTURE=bench/runners/wasm/simd/i32x4_add.wasm
echo "[check_jit_releasesafe] zig build -Doptimize=ReleaseSafe ..."
zig build -Doptimize=ReleaseSafe >/dev/null
echo "[check_jit_releasesafe] zwasm run --engine=jit $FIXTURE ..."
if zig-out/bin/zwasm run --engine=jit "$FIXTURE" >/dev/null 2>&1; then
    echo "[check_jit_releasesafe] OK — --engine=jit runs in ReleaseSafe (D-245 void path fixed)."
else
    rc=$?
    echo "[check_jit_releasesafe] FAIL (exit $rc) — --engine=jit crashed in ReleaseSafe; D-245 callee-saved-preservation regressed (see src/engine/codegen/shared/entry.zig invokeAndCheckVoid)." >&2
    exit 1
fi

# §15.5 chunk 1: the no-arg VOID path above does NOT cover the i32 RESULT path
# (`runner.runI32Export` → `entry.invokeAndCheck` → `jitTrampoline`). The probe
# step compiles a fresh `core` PINNED to ReleaseSafe + a host that holds live
# callee-saved values across the JIT call, asserting the result (==42) and that
# no live host slice was corrupted by the cohort clobber. Non-zero exit = the
# RESULT-path trampoline regressed.
echo "[check_jit_releasesafe] zig build jit-result-probe-releasesafe (RESULT path) ..."
if zig build jit-result-probe-releasesafe >/dev/null 2>&1; then
    echo "[check_jit_releasesafe] OK — runI32Export preserves the host cohort in ReleaseSafe (D-245 result path fixed)."
else
    rc=$?
    echo "[check_jit_releasesafe] FAIL (exit $rc) — runI32Export crashed/mismatched in ReleaseSafe; D-245 RESULT-path preservation regressed (see src/engine/codegen/shared/entry.zig jitTrampoline / invokeAndCheck)." >&2
    exit 1
fi
