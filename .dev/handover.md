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

## Current state — Phase 9 / §9.7 in-flight (9.7-a..aa landed); **9.7-ab NEXT**

9.7-aa: x86_64 i*x*.neg (4 ops). 3-instr emitV128IntNeg
helper (PXOR + PSUB_<shape> + MOVAPS); no new encoders.
Total SIMD ops handled: 143.

**9.7-ab NEXT** — FP convert family (4-6 ops):
f32x4.convert_i32x4_{s,u} + f64x2.convert_low_i32x4_{s,u}
+ f64x2.promote_low_f32x4 + f32x4.demote_f64x2_zero. SSE
encoders: CVTDQ2PS / CVTDQ2PD (signed direct) + unsigned
synthesis (cranelift recipe). f64x2.promote_low: CVTPS2PD.
f32x4.demote: CVTPD2PS. Likely 4-6 new encoders + 4-6
wrappers. Unsigned-i32→FP synthesis is non-trivial
(cranelift uses bit-magic with float constants — needs
const-pool!). Defer u-variants to const-pool chunk if
ADR-0042 still pending; signed variants doable inline.

Subsequent: 9.7-ac+ (i32x4.trunc_sat_f*x*_*), 9.7-ad+
(i8x16.swizzle PADDUSB-broadcast inline-synth), 9.7-ae+
(i8x16.shuffle const-pool dep), 9.7-af (v128.const +
const-pool finalisation).

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
§9.7 in-flight (x86_64 SSE4.1+SSE4.2; 9.7-a..aa landed; 9.7-ab NEXT).
**Branch**: `zwasm-from-scratch`。
