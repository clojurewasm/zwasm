#!/usr/bin/env bash
# scripts/eval/conformance_sweep.sh — measured spec conformance, per level and
# per Wasm 3.0 proposal, on both the interpreter and the JIT lane.
#
# Backs §1.1–§1.6 of `.dev/meta_audits/2026-08-14-product-evaluation.md`.
#
# Deliberately runs at the CI-equivalent optimize level (no `-Doptimize`, i.e.
# core=Debug / runners=ReleaseSafe per ADR-0177) so the numbers describe the
# configuration `scripts/ci_gate.sh` actually gates on.
#
# Usage: bash scripts/eval/conformance_sweep.sh [outdir]
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:-$ROOT/private/eval/conformance}"
cd "$ROOT"
mkdir -p "$OUT"

echo "=== interpreter lane (CI-equivalent optimize) ==="
for s in test-spec-assert test-spec-wasm-2.0-assert test-spec-simd \
         test-spec-threads-assert test-spec-wasm-3.0-assert test-component-spec; do
  echo "--- $s"
  zig build "$s" 2>&1 | tee "$OUT/${s}.txt" \
    | grep -E 'passed|total:|manifests=' | tail -12
done

echo
echo "=== Wasm 3.0 JIT lane, isolated per proposal ==="
# The wasm-3.0 runner is the only one that honours ZWASM_SPEC_ENGINE. Running
# it per-proposal is what localises the memory64 abort (it does not reproduce
# on a single manifest, only across the whole proposal in one process).
RUNNER="$(find .zig-cache -name 'zwasm-spec-wasm-3-0-assert' -type f 2>/dev/null | head -1)"
if [ -z "$RUNNER" ]; then
  echo "runner not built; run 'zig build test-spec-wasm-3.0-assert' first" >&2
  exit 1
fi
for p in memory64 tail-call exception-handling gc function-references multi-memory; do
  root="$OUT/root_$p"
  rm -rf "$root"; mkdir -p "$root"
  ln -sfn "$ROOT/test/spec/wasm-3.0-assert/$p" "$root/$p"
  ZWASM_SPEC_DETAIL=1 ZWASM_SPEC_ENGINE=jit "$RUNNER" "$root" > "$OUT/jit_$p.txt" 2>&1
  ec=$?
  printf '%-22s exit=%-4s %s\n' "$p" "$ec" \
    "$(grep -E '^\[.*JIT:' "$OUT/jit_$p.txt" | head -1)"
  [ "$ec" -ne 0 ] && echo "    ^ non-zero exit: see $OUT/jit_$p.txt"
done

echo
echo "=== ReleaseFast harness check (releases ship ReleaseFast; CI does not test it) ==="
zig build test-spec-wasm-2.0-assert -Doptimize=ReleaseFast > "$OUT/rf_2_0.txt" 2>&1
echo "wasm-2.0 assert @ReleaseFast: exit=$? (142 = SIGALRM after the runner's own SEGV diag)"
grep -E 'SEGV' "$OUT/rf_2_0.txt" | tail -2
