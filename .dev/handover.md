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

## Current state — Phase 9 / §9.7 in-flight (9.7-a..l [x]); **9.7-m NEXT**

9.7-l landed at ea3bcedb: signed lt/gt/le/ge for 8/16/32-bit
shapes (12 ops). New encoders encPcmpgtB/W/D (SSE2) + new
parametric helper `emitV128IntCmpSigned(encoder_gt, kind)`
covering all 4 variants via operand swap (lt/ge) + PXOR-with-
all-ones NOT (le/ge). Same commit also splits op_simd.zig
(2064 LOC, broke §A2 hard cap) into op_simd.zig (1156 source)
+ op_simd_test.zig (923 tests) per emit.zig D-030 mirror.
Total SIMD ops handled: 50.

Three-host gate at ea3bcedb: Mac unit 1414/0/12 + gates ✓;
OrbStack at known D-054 baseline (211/1/20 + 1398/1426);
windowsmini full green (212/0/20 + every runner green).

**9.7-m NEXT** — i64x2 signed compares + the SSE4.2 vs synthesis
decision. Two options for i64x2.gt_s (which spec mandates):
- **(A) Amend ADR-0041 to SSE4.2 baseline.** PCMPGTQ direct
  (1 instr). Hardware support: ~100% on x86_64 from 2008
  Nehalem onward; pre-Nehalem Core 2 / Atom Bonnell are the
  exclusion. Cleaner code; narrower target.
- **(B) Synthesise PCMPGTQ from SSE4.1 primitives.** Cranelift
  recipe: ~5 instructions via PCMPGTD on the high+low dword
  halves + AND/OR combine. Preserves baseline; more code.

Step 0 should: walk cranelift's exact synthesis recipe for
i64x2.gt_s in `~/Documents/OSS/wasmtime/cranelift/codegen/src/
isa/x64/...`; verify Steam Hardware Survey / Wasm ecosystem
SSE4.2 adoption; recommend (A) or (B) with ADR if (A).

Pick depends on philosophy: zwasm v2's stated principles favor
(A) (P3 cold-start: 1 instr beats 5; ROADMAP §A12: simplicity).
But ADR-0041 §5 explicitly mandates SSE4.1 — amending requires
deliberate ADR work. Either is defensible.

Other 9.7-m candidate scope: unsigned compares (ult/ugt/ule/uge,
12 ops for 8/16/32-bit + 0 for i64x2). Cranelift synth: PXOR
with sign-mask 0x80...80 to bias both operands, then signed
PCMPGT. Or PMINU/PMAXU + PCMPEQ for some shapes. Also probably
~150-200 LOC; could bundle if 9.7-m's i64x2 work stays small.

Subsequent: 9.7-n+ (FP compare CMPPS/PD), 9.7-o+ (FP arith),
9.7-p+ (bitwise ops + select), 9.7-q+ (conversion +
narrow/extend + shuffle PSHUFB), 9.7-r (v128.const via ADR-0042
const-pool).

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
