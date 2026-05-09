# Session handover

> Read this at session start. **Replace** (not append) the `Current state`
> block + the `Active task` table at session end. Keep ≤ 100 lines.

## Next files to read on a cold start (in order)

1. `.dev/handover.md` (this file).
2. `.dev/ROADMAP.md` §9 Phase Status widget + §9.8 task table — Phase 8 active.
3. `.dev/debt.md` — D-054 + D-055 + 9 other rows.
4. `.dev/lessons/INDEX.md` — keyword-grep for the active task domain
   (focus: hoist-branch-targets-as-pc, regalloc, coalescer).
5. `.dev/decisions/0031_zir_hoist_pass.md` (D-053 root-cause amend per 8a.6).
6. `.dev/optimisation_log.md` (F/R/O ledger; 8b adoption discipline).

## Current state — Phase 9 / §9.7 in-flight (9.7-a..k [x]); **9.7-l NEXT**

9.7-k landed at 22d62cfd: int compare eq/ne family (8 ops, all
4 widths). Adds encPcmpeqB/W/D (SSE2) + encPcmpeqQ (SSE4.1).
eq handlers reuse 9.7-b's emitV128IntBinop unchanged. ne handler
applies NOT-via-PXOR-with-all-ones (PCMPEQB scratch, scratch on
XMM14). Total SIMD ops handled: 38.

Three-host gate at 22d62cfd: Mac unit 1408/0/12 + gates ✓;
OrbStack at known D-054 baseline (211/1/20 + 1392/1420);
windowsmini full green (212/0/20 + every runner green).

**9.7-l NEXT** — int compare signed lt/gt/le/ge family. Wasm ops:
- i8x16/i16x8/i32x4 lt_s/gt_s/le_s/ge_s = 12 ops.
- i64x2 lt_s/gt_s/le_s/ge_s = 4 ops (no _u for i64x2).

Native SSE encoders:
- PCMPGTB/W/D (SSE2): signed greater-than (a > b → all-ones lane).
- PCMPGTQ (SSE4.2 — **beyond ADR-0041 baseline**!): i64x2.gt_s.

Strategy:
- gt_s: direct PCMPGT_<shape>(dst, lhs, rhs).
- lt_s: PCMPGT with operands swapped → MOVAPS dst, rhs; PCMPGT
  dst, lhs.
- le_s: NOT(gt_s) — PCMPGT then PXOR with all-ones.
- ge_s: NOT(lt_s).

i64x2.gt_s blocker: SSE4.2 PCMPGTQ exceeds ADR-0041 §"5. SSE4.1
minimum baseline". Cranelift's SSE4.1 fallback uses a 5-instr
synthesis: PCMPGTD + PSHUFD + PSUBQ + AND tricks (or simpler
emulated via 2× PCMPGTD half-comparisons combined with PCMPEQD).

Decision needed: relax baseline to SSE4.2 (ADR-0041 amend), OR
implement i64x2.gt_s synthesis. Survey for 9.7-l should:
1. Check Steam Hardware Survey / cranelift's MIN_X86_64_FEATURES
   for SSE4.2's adoption rate (essentially 100% on 2008+ CPUs;
   Atom Bonnell/Pineview pre-2010 lacks it).
2. Document the cranelift i64x2.gt_s synthesis recipe.
3. Pick: amend ADR-0041 to SSE4.2 baseline (1-line decision —
   cleaner code, narrower hardware support) vs synthesise
   (preserves baseline, ~5 instr per i64x2 cmp).

Subsequent chunks: 9.7-m (unsigned compares ult/ugt/ule/uge —
synth via PXOR-with-sign-mask + PCMPGT_signed; or via PMINU /
PMAXU + PCMPEQ), 9.7-n+ (FP compare CMPPS/PD), 9.7-o+ (FP arith),
9.7-p+ (bitwise ops + select), 9.7-q+ (conversion + narrow/extend
+ shuffle PSHUFB), 9.7-r (v128.const via ADR-0042 const-pool).

## Open structural debt (pointers — full list in `.dev/debt.md`)

- **D-054** (OrbStack-only as-loop-broke) — Rosetta JIT-emulation
  artefact; baseline 211/1/20 carried as known.
- **D-055** (x86_64 prologue inject) — blocked-by D-052 prologue
  extract.
- 9 `blocked-by:` rows: D-007/D-010/D-016/D-018/D-020/D-021/D-022/
  D-026/D-028/D-052 — barriers all hold.

Closed Phase 8b artefacts (preserved for Phase 12 + Phase 15
reference) live in git: ADRs 0035-0040, lessons indexed in
`.dev/lessons/INDEX.md`, code in `src/ir/coalesce/`,
`src/engine/codegen/shared/regalloc.zig` (LIFO free-pool),
`src/engine/codegen/aot/`. No need to duplicate pointers here —
`git log` is the authoritative lookup.

**Phase**: Phase 9 (SIMD-128, ADR-0041). §9.5 [x] (ARM64 NEON pt 1),
§9.6 [x] (ARM64 NEON pt 2), §9.7 NEXT (x86_64 SSE4.1).
**Branch**: `zwasm-from-scratch`。
