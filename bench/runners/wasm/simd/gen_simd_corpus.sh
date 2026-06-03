#!/usr/bin/env bash
# Generate the §11.3 SIMD per-op micro-bench corpus (D-074 / 11.3-simd-gap).
#
# Each fixture is a compute-only `_start` that hammers ONE SIMD op class in a
# tight loop, accumulating into a v128 that is `v128.store`d after the loop so
# optimizing runtimes (Cranelift / LLVM in wasmtime / wasmer) cannot DCE the
# work. No WASI imports → runnable via `zwasm run --engine=jit` (ADR-0136; the
# interp has no SIMD) AND via wasmtime / wazero / wasmer for the gap analysis.
#
# Mac-only (needs `wat2wasm` from the nix dev shell). Run:
#   nix develop --command bash bench/runners/wasm/simd/gen_simd_corpus.sh
# Emits <name>.wat + <name>.wasm beside this script. The .wat are the
# hand-authored source of truth (no copy from v1); the .wasm are committed
# derivatives (per the bench data policy, ROADMAP §11.2 test-data rule).
set -euo pipefail
cd "$(dirname "$0")"

ITERS=5000000

# name              | init v128.const         | op             | operand v128.const
CORPUS=(
  "i32x4_add        | i32x4 0 0 0 0           | i32x4.add      | i32x4 1 2 3 4"
  "i32x4_sub        | i32x4 99 99 99 99       | i32x4.sub      | i32x4 1 1 1 1"
  "i32x4_mul        | i32x4 1 1 1 1           | i32x4.mul      | i32x4 3 1 1 1"
  "i32x4_min_s      | i32x4 7 7 7 7           | i32x4.min_s    | i32x4 3 3 3 3"
  "i16x8_mul        | i16x8 1 1 1 1 1 1 1 1   | i16x8.mul      | i16x8 3 1 1 1 1 1 1 1"
  "i8x16_add        | i8x16 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 | i8x16.add | i8x16 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1"
  "f32x4_add        | f32x4 0 0 0 0           | f32x4.add      | f32x4 1 1 1 1"
  "f32x4_mul        | f32x4 1 1 1 1           | f32x4.mul      | f32x4 1.0000001 1 1 1"
  "f32x4_div        | f32x4 1 1 1 1           | f32x4.div      | f32x4 1.0000001 1 1 1"
  "f32x4_min        | f32x4 1 1 1 1           | f32x4.min      | f32x4 0.5 0.5 0.5 0.5"
  "v128_and         | i32x4 -1 -1 -1 -1       | v128.and       | i32x4 2147483647 -1 -1 -1"
  "i8x16_swizzle    | i8x16 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 | i8x16.swizzle | i8x16 15 14 13 12 11 10 9 8 7 6 5 4 3 2 1 0"
)

for row in "${CORPUS[@]}"; do
  IFS='|' read -r name init op operand <<<"$row"
  name="$(echo "$name" | xargs)"; init="$(echo "$init" | xargs)"
  op="$(echo "$op" | xargs)"; operand="$(echo "$operand" | xargs)"
  cat > "$name.wat" <<EOF
;; §11.3 SIMD micro-bench — $op (one op class, anti-DCE via v128.store).
(module
  (memory (export "memory") 1)
  (func (export "_start")
    (local \$i i32)
    (local \$a v128)
    (local.set \$i (i32.const $ITERS))
    (local.set \$a (v128.const $init))
    (block \$done
      (loop \$loop
        (local.set \$a ($op (local.get \$a) (v128.const $operand)))
        (local.set \$i (i32.sub (local.get \$i) (i32.const 1)))
        (br_if \$loop (local.get \$i))))
    (v128.store (i32.const 0) (local.get \$a))))
EOF
  wat2wasm "$name.wat" -o "$name.wasm"
  echo "[gen_simd_corpus] $name.wasm"
done
echo "[gen_simd_corpus] ${#CORPUS[@]} fixtures generated."
