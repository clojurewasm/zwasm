# Session handover

> Read this at session start. **Replace** (not append) the `Current state`
> block + the `Active task` table at session end. Keep ≤ 100 lines.

## Next files to read on a cold start (in order)

1. `.dev/handover.md` (this file).
2. `.dev/ROADMAP.md` §9 Phase Status widget + §9.7 row — Phase 9 active.
3. `.dev/debt.md` — D-054 + D-055 + 9 other rows.
4. `.dev/lessons/INDEX.md` — keyword-grep for the active task domain
   (focus: simd compare ops, x86_64 SSE/PCMPGT idioms, ADR-0041 §5
   baseline rationale).
5. `.dev/decisions/0041_simd_128_design.md` (SSE4.2 baseline post-9.7-m
   amendment; §5 + Alternative E hold the rationale).
6. `private/notes/p9-9.7-m-survey.md` (gitignored; cranelift recipe +
   adoption data) — only if revisiting the SSE4.2 baseline call.

## Current state — Phase 9 / §9.7 in-flight (9.7-a..ad landed); **9.7-ae NEXT**

9.7-ad: x86_64 FP unop family (12 ops). abs/neg via inline
sign-mask synthesis (PCMPEQB ones + PSLL{D,Q}-imm 31/63);
ceil/floor/trunc/nearest via SSE4.1 ROUND{PS,PD} imm with
precision-exception suppression. 3 new encoders. Total SIMD
ops handled: 160.

**9.7-ae NEXT** — FP convert u-variants + trunc-sat (~6 ops):
f32x4.convert_i32x4_u, f64x2.convert_low_i32x4_u, plus 4
trunc-sat ops (i32x4.trunc_sat_f32x4_{s,u}, i32x4.trunc_sat_
f64x2_{s,u}_zero). Cranelift recipes (`lower.isle:3761+`)
use const-pool float magic numbers (e.g. 2^31 for the u-
variants, +0.0 / 2^31 for trunc-sat NaN/clamp masks).
Pending: ADR-0042 const-pool plumbing decision — either
land 9.7-ae as inline-synth (likely 12-15 instr per op via
PCMPEQB+PSLL/SUB chains) or land ADR-0042 first then 9.7-ae
in const-pool form (~5 instr per op). Inline-synth is the
faster path; defer const-pool-final to 9.7-ag.

Subsequent: 9.7-af (i8x16.shuffle const-pool dep — defer
until 9.7-ag), 9.7-ag (v128.const + ADR-0042 const-pool
finalisation), 9.7-ah+ (i*x*.popcnt + i16x8.q15 + misc
remaining ops).

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

**Phase**: Phase 9 (SIMD-128, ADR-0041 — SSE4.2 baseline post-9.7-m).
§9.5 [x] (ARM64 NEON pt 1), §9.6 [x] (ARM64 NEON pt 2),
§9.7 in-flight (x86_64 SSE4.1+SSE4.2; 9.7-a..ad landed; 9.7-ae NEXT).
**Branch**: `zwasm-from-scratch`。
