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

## Current state — Phase 9 / §9.7 in-flight (9.7-a..t landed); **9.7-u NEXT**

9.7-t: x86_64 packed shifts shl/shr_s/shr_u for i16x8 +
i32x4 + i64x2 (8 ops). 8 new shift-reg encoders + helper
`emitV128IntShift(encoder, mask_imm)`. AND mask + MOVD
count→xmm + MOVAPS + <shift>. i8x16 + i64x2.shr_s deferred
to 9.7-u (synthesis-only). Total SIMD ops handled: 115.

**9.7-u NEXT** — synthesis-only shifts (4 ops):
i8x16.{shl, shr_s, shr_u} + i64x2.shr_s. Cranelift recipes:

- i8x16.shl(v, c): PSLLW(v, c) + AND with shift-mask
  constant (8 byte-positions per c value × 8 c values =
  needs const-pool table OR runtime mask synthesis via
  shift+broadcast). cranelift uses const-pool lookup.
- i8x16.shr_u: PSRLW + AND with mask.
- i8x16.shr_s: PSRLW + sign-bit duplication via XOR + SUB.
- i64x2.shr_s: cranelift PSRLQ + sign-bit fixup via
  PSRAD on doubled-broadcast OR per-lane synthesis using
  PSRLQ + PXOR + PSUBQ with sign-bit mask.

These recipes need const-pool plumbing (ADR-0042) for the
mask constants. Likely needs 2-3 new encoders + 4 distinct
synthesis helpers + const-pool entries. ~300 src + ~120 test.
ADR optional — synthesis is cranelift-published.

Subsequent: 9.7-v+ (conversion + narrow/extend + shuffle
PSHUFB), 9.7-w (abs/neg via const-pool sign mask), 9.7-x
(v128.const finalisation).

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
§9.7 in-flight (x86_64 SSE4.1+SSE4.2; 9.7-a..t landed; 9.7-u NEXT).
**Branch**: `zwasm-from-scratch`。
