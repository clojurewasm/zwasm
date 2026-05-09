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

## Current state — Phase 9 / §9.7 in-flight (9.7-a..s landed); **9.7-t NEXT**

9.7-s: x86_64 per-shape all_true + bitmask reductions (8 ops).
4 new encoders (MOVMSKPS/MOVMSKPD/PMOVMSKB RM-form xmm→gpr;
PACKSSWB). 4 all_true via 5-instr cranelift recipe (PXOR +
PCMPEQ_<lane> + PTEST + SETZ + MOVZX); bitmask shapes —
i8x16 PMOVMSKB direct, i32x4 MOVMSKPS direct, i64x2 MOVMSKPD
direct, i16x8 PACKSSWB+PMOVMSKB+SHR. Total SIMD ops
handled: 107.

**9.7-t NEXT** — i*x* shifts (shl / shr_s / shr_u for
i8x16/i16x8/i32x4/i64x2 = 12 ops). SSE2 has packed shift-by-
GPR/imm: PSLLW/D/Q + PSRLW/D/Q + PSRAW/D (no PSRAQ — SSE
lacks signed 64-bit shift; needs synthesis per cranelift).
i8x16 has no native packed byte shift; synthesis via word
shifts + AND-mask. Likely 6 new encoders (PSLLW/D + PSRLW/D
+ PSRAW/D variants on register; existing PSRLQ/PSLLQ-imm
extend for register form) + per-shape helpers. ~250 src +
~120 test. PSRAQ synthesis adds complexity; may split
i64x2.shr_s into 9.7-u if recipe is too large.

Subsequent: 9.7-u+ (conversion + narrow/extend + shuffle
PSHUFB; abs/neg via const-pool sign mask), 9.7-v (v128.const
via ADR-0042 const-pool finalisation).

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
§9.7 in-flight (x86_64 SSE4.1+SSE4.2; 9.7-a..s landed; 9.7-t NEXT).
**Branch**: `zwasm-from-scratch`。
