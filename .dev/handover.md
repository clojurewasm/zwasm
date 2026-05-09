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

## Current state — Phase 9 / §9.7 in-flight (9.7-a..f [x]); **9.7-g NEXT**

9.7-f landed at 20751909: i32x4/i64x2 replace_lane via PINSRD
(SSE4.1 RVMI 3A 22 /r ib) + PINSRQ (REX.W mandatory). New
parametric handler helper `emitV128IntReplaceLane32Or64(is_64)`
+ 1-line wrappers. MOVAPS-elision when dst aliases vec. Total
SIMD ops handled: 15.

Three-host gate at 20751909: Mac unit 1371/0/12 + gates ✓;
OrbStack at known D-054 baseline (211/1/20 + 1355/1383); windowsmini
full green (212/0/20 + every runner green).

**9.7-g NEXT** — narrow-int lane access: i8x16 / i16x8 splat +
extract_lane (signed/unsigned) + replace_lane. Encoders needed:
PINSRB (66 [REX?] 0F 3A 20 /r ib) + PINSRW (66 [REX?] 0F C4 /r
ib — note SSE2 base, different escape from SSE4.1 family) +
PEXTRB (3A 14) + PEXTRW (0F C5 /r ib for "old" SSE2 form OR 0F
3A 15 for SSE4.1 mem-capable form). Sign/unsigned variants need
MOVSX / MOVZX after PEXTRB/W (i8 → i32, i16 → i32). Splat needs
PSHUFB-lane-mask (i8) or PSHUFD-after-PINSRW (i16).

This is the largest sub-chunk in the lane access family — likely
~400-500 LOC including encoders + sign-ext logic + tests. Step 0
will partition: bundle all narrow-int ops in one chunk, OR
separate splat / extract / replace.

Subsequent: 9.7-h (FP lane access — f32x4/f64x2 splat / extract /
replace), 9.7-i (compare family — PCMPEQ*, PCMPGT*), 9.7-j (FP
arith), 9.7-k (FP compare), 9.7-l (conversion + shuffle PSHUFB +
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
