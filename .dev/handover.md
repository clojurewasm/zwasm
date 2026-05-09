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

## Current state — Phase 9 / §9.7 in-flight (9.7-a..e [x]); **9.7-f NEXT**

9.7-e landed at 3ac43dad: lane access foundation. Adds
`encPshufd` (SSE2 dword shuffle) + `encPextrD` (SSE4.1 dword
extract — note ModR/M.reg carries source XMM, ModR/M.r/m the
GPR). Handlers `emitI32x4Splat` (MOVD + PSHUFD broadcast) +
`emitI32x4ExtractLane` (single PEXTRD). Total SIMD ops handled:
13. Edge fixtures deferred to §9.9 (edge runner is Mac aarch64-
only; SIMD spec_assert + wast integration in §9.9 will exercise
all hosts).

Three-host gate at 3ac43dad: Mac unit 1364/0/12 + gates ✓;
OrbStack at known D-054 baseline (211/1/20); windowsmini full
green (212/0/20 + every runner green).

**9.7-f NEXT** — lane access bundle: rest of the splat family
(i8x16 / i16x8 / i64x2 / f32x4 / f64x2), other extract_lane
variants (signed/unsigned narrow: i8x16 / i16x8; i64x2 wide;
f32x4 / f64x2), and replace_lane (i8/16/32/64/f32/f64). Per
LOOP.md chunk-bundle: same op family, same handler shape (only
encoder + lane-width differs). Likely 200-400 LOC.

Encoders to add (Step 0 will scope exactly):
- splat helpers: PINSRB / PINSRW direct, PSHUFB lane-zero mask
  (i8x16.splat); PINSRW × N + PSHUFD (i16x8.splat); MOVQ +
  PUNPCKLQDQ (i64x2.splat); SHUFPS / MOVDDUP (f32/f64 splats).
- PEXTRB / PEXTRW / PEXTRQ (extract narrow + i64).
- PINSRB / PINSRW / PINSRD / PINSRQ (replace_lane).

Subsequent: 9.7-g (compare family — PCMPEQ*, PCMPGT*), 9.7-h
(FP arith — ADDPS / ADDPD / MULPS / DIVPS), 9.7-i (FP compare
— CMPEQPS / CMPLTPS), 9.7-j (conversion + shuffle PSHUFB +
v128.const via ADR-0042 const-pool).

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
