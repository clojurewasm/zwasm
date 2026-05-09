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

## Current state — Phase 9 / §9.7 in-flight (9.7-a..g [x]); **9.7-h NEXT**

9.7-g landed at b9d91a66: narrow-int extract+replace (6 ops).
Adds encPextrB (SSE4.1, RMI 3A 14) + encPextrW (SSE2, 0F C5
RMI but **opposite REX role assignment** — gpr in reg, xmm in
r/m) + encPinsrB (SSE4.1, RVMI 3A 20) + encPinsrW (SSE2, 0F C4
RVMI). Parametric extract helper covers signed (PEXTR + MOVSX)
/ unsigned (zero-extends natively). Total SIMD ops handled: 21.

Three-host gate at b9d91a66: Mac unit 1380/0/12 + gates ✓;
OrbStack at known D-054 baseline (211/1/20 + 1364/1392);
windowsmini full green (212/0/20 + every runner green).

**9.7-h NEXT** — splat siblings (i8x16 / i16x8 / i64x2) + FP
lane access (f32x4 / f64x2 splat + extract + replace). Encoders
needed:
- i8x16.splat: MOVD + PXOR (zero mask) + PSHUFB (broadcast lane
  0 via zero-index mask). New encoders encPxor (SSE2 0F EF) +
  encPshufb (SSSE3 0F 38 00). Uses XMM14/15 scratch as zero ctrl.
- i16x8.splat: MOVD + PSHUFLW (broadcast low word to lanes 0-3)
  + PSHUFD (broadcast lower 64 to upper). New encoder encPshuflw
  (F2 0F 70 /r ib).
- i64x2.splat: MOVQ + PUNPCKLQDQ (broadcast low qword). New
  encPunpcklqdq (66 0F 6C /r).
- f32x4.splat: SHUFPS xmm, xmm, 0x00 (or PSHUFD on integer
  domain — XMM source already, no MOVD needed). encShufps (F-class).
- f64x2.splat: MOVDDUP (F2 0F 12 /r). Or MOVAPS + UNPCKLPD.
- f32x4.extract_lane: MOVHLPS / SHUFPS or PEXTRD (XMM result is
  XMM, not GPR — need to be careful with op_simd's resolution
  paths). f64x2.extract_lane: MOVHLPS / SHUFPD.
- f32x4.replace_lane: INSERTPS (66 0F 3A 21 /r ib).
  f64x2.replace_lane: MOVLHPS / SHUFPD / blend.

Likely 400-500 LOC; consider splitting into 9.7-h (int splat
narrow), 9.7-i (FP splat + extract + replace), 9.7-j onwards
(compare / FP arith / etc.). Step 0 will scope.

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
