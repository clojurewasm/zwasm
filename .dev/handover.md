# Session handover

> Read this at session start. **Replace** (not append) the `Current state`
> block + the `Active task` table at session end. Keep ≤ 100 lines.

## Next files to read on a cold start (in order)

1. `.dev/handover.md` (this file).
2. `.dev/ROADMAP.md` §9 Phase Status widget + §9.9 row — Phase 9 active.
3. `.dev/debt.md` — D-063 / D-064 / D-065 + 11 `blocked-by:` rows.
4. `.dev/lessons/INDEX.md` — keyword-grep for the active task domain
   (focus: simd ops, ARM64 NEON, ADR-0041 §5).
5. `.dev/decisions/0041_simd_128_design.md` (SSE4.2 baseline).

## Current state — Phase 9 / §9.9 in-flight; **9.9-f-8 NEXT — wire i64x2.mul (sub-op 213) end-to-end (validator binop arm + multi-instr synthesis on ARM64 NEON, since NEON has no `MUL.2D` form)**

9.9-f-7 (`<pending-sha>`): added 9 ARM64 emit handlers
(`emitI{8x16,16x8,32x4,64x2}{Abs,Neg}` + `emitI8x16Popcnt`)
reusing the existing `emitV128Unop` helper; added 9 NEON
encoders (`encAbs/Neg/Cnt`); wired 9 dispatch arms; fixed
pre-existing `emitV128Bitselect` SPILL-EXEMPT comment placement.

**Mac aarch64 simd_assert_runner totals after 9.9-f-7**:
**3366 PASS** (was 2893, +473) / **5 FAIL** (was 11, -6) /
1703 SKIP. Tests: 1554/1566 Mac.

Residual 5 fails:
- 2× simd_i64x2_arith.0/.12 NotImplemented (i64x2.mul sub-op
  213 unwired in validator + emit-side multi-instr synthesis
  required — D-064, 9.9-f-8 scope).
- 2× simd_const call_indirect v128 Trap (D-063).
- simd_const.388 BadValType (parse-side gap).

**Next — 9.9-f-8** (i64x2.mul, ADR-grade):
- Add `213 => opSimdBinop` arm in `validator.zig` 94..211 range.
- Add `213 => emit(.@"i64x2.mul", 0, 0)` in `lower.zig` (likely
  already routed; verify).
- ARM64 emit handler: NEON has no `MUL.2D`. Synthesis options:
  (a) UMOV X17/X18 ← Vn.D[0/1]; UMOV X9/X10 ← Vm.D[0/1]; MUL
      X17 ← X17,X9; MUL X18 ← X18,X10; INS Vd.D[0]/Vd.D[1].
  (b) `MUL Vd.4S` + lane shuffle for 64-bit semantics
      (cranelift / wasmtime reference).
  Strategy choice → ADR if non-trivial.
- x86_64 mirror at the same chunk (`PMULDQ` requires SSE4.1
  per ADR-0041; result needs combining via PADDQ + shifts).

After §9.9: §9.10 (smoke benches + gap analysis), §9.11 (audit
+ SHA backfill), §9.12 (open Phase 10).

## Open structural debt (pointers — full list in `.dev/debt.md`)

- **D-063** (simd_const.386 call_indirect v128 Trap) — `now`.
- **D-064** (i64x2.mul end-to-end wire) — `now`; 9.9-f-8 scope.
- **D-065** (arm64/inst_neon.zig 2029 LOC > 2000 cap) —
  blocked-by ADR for source-split (mirror of D-057 / ADR-0030
  for x86_64 op_simd.zig).
- **D-055** (x86_64 prologue inject) — blocked-by D-052.
- **D-057** (x86_64 op_simd.zig 4442 LOC hard-cap) — blocked-by
  ADR for source-split landing.
- 10 `blocked-by:` rows: D-007/D-010/D-016/D-018/D-020/D-021/
  D-022/D-026/D-028/D-052 — barriers all hold this resume.

Closed Phase 8b artefacts (preserved for Phase 12 + Phase 15)
live in git: ADRs 0035-0040, lessons in `.dev/lessons/INDEX.md`,
code in `src/ir/coalesce/`, regalloc.zig LIFO free-pool,
`src/engine/codegen/aot/`. `git log` is authoritative.

**Phase**: Phase 9 (SIMD-128, ADR-0041 — SSE4.2 baseline).
§9.5 [x] (ARM64 NEON pt 1), §9.6 [x] (ARM64 NEON pt 2),
§9.7 [x] (x86_64 SSE4.1+SSE4.2; 9.7-a..bb landed),
§9.8 [x] (scope absorbed per ADR-0044),
§9.9 in-flight (9.9-a..c + 9.9-d-1..7 + 9.9-e-1..2 + 9.9-f-1..7
landed; 9.9-f-8 NEXT — i64x2.mul end-to-end).
**Branch**: `zwasm-from-scratch`。
