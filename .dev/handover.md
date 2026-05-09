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

## Current state — Phase 9 / §9.7 in-flight (9.7-a..y landed); **9.7-z NEXT**

9.7-y: x86_64 i*x*.narrow_*_{s,u} (4 ops). 3 new encoders
(PACKSSDW + PACKUSWB SSE2; PACKUSDW SSE4.1) + 4 wrappers via
emitV128IntBinop. Total SIMD ops handled: 135.

**9.7-z NEXT** — i8x16.swizzle (1 op) + i*x*.abs (4 ops):
i8x16.swizzle uses PSHUFB directly (SSE3 0F 38 00; encoder
exists from 9.7-h splat). Wasm semantics: out[i] =
v[idx[i]] if idx[i] < 16 else 0; PSHUFB matches when
high bit of idx is interpreted as "zero output". This is
1 instr.

i*x*.abs: cranelift uses SSSE3 PABSB/W/D for i8x16/i16x8/
i32x4. i64x2.abs needs synthesis (no PABSQ in SSE; cranelift
uses PXOR with sign-mask). 3 new encoders (PABSB/W/D) + 4
wrappers (1 unary direct + 1 i64x2 synthesis). ~120 src +
~60 test, no ADR.

Subsequent: 9.7-aa+ (i*x*.neg via PSUBB/W/D/Q from zero,
or PXOR+PSUBQ; 4 ops), 9.7-ab+ (FP convert i↔f + trunc-
sat), 9.7-ac (i8x16.shuffle ADR-0042 const-pool dep),
9.7-ad (v128.const finalisation).

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
§9.7 in-flight (x86_64 SSE4.1+SSE4.2; 9.7-a..y landed; 9.7-z NEXT).
**Branch**: `zwasm-from-scratch`。
