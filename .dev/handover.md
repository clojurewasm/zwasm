# Session handover

> Read this at session start. **Replace** (not append) the `Current state`
> block + the `Active task` table at session end. Keep ≤ 100 lines.

## Next files to read on a cold start (in order)

1. `.dev/handover.md` (this file).
2. `.dev/ROADMAP.md` §9 Phase Status widget + §9.7 row — Phase 9 active.
3. `.dev/debt.md` — D-055 / D-057 + 10 `blocked-by:` rows.
4. `.dev/lessons/INDEX.md` — keyword-grep for the active task domain
   (focus: simd ops, x86_64 SSE/SSE4.1/SSE4.2, ADR-0041 §5).
5. `.dev/decisions/0041_simd_128_design.md` (SSE4.2 baseline post-9.7-m
   amendment).

## Current state — Phase 9 / §9.9 in-flight; **9.9-e NEXT — v128 PARAM marshal + v128 local frame layout per ADR-0046 (unblocks simd_select.0 + simd_const.387 fixtures)**

9.9-d-6 (`ffe75802`): `populateShapeTags` (D-061) discharged.
Extends `any_simd` trigger to v128 in
`func.sig.params`/`results`/`func.locals`; handles
`local.get` / `local.tee` with type-aware tagging from
`func.localValType(payload)`; falls through to
`liveness.stackEffect` for catch-all push counting. The prior
walk's `else => false` arm dropped vreg increments for any op
outside its explicit lists, drifting tag indices for any
function with scalar binops between SIMD ops. `stackEffect` +
`StackEffect` are now `pub`.

**Mac aarch64 simd_assert_runner totals after 9.9-d-6**:
226 PASS / 36 FAIL / 296 SKIP — **unchanged**. The
populateShapeTags fix is a prerequisite for v128 select
dispatch but the `simd_select.0` fixture is still blocked on
v128 local.get/set/tee handlers (arm64+x86_64 emit explicitly
reject v128 type; frame layout uses 8-byte slots not 16).
Discharging that is §9.9-e's scope.

Residual 36 fails (same shape as 9.9-d-4):
- 3 compile UnsupportedOp — `simd_select.0` + `simd_const.387`
  + `simd_align.90` (all blocked on v128 frame-layout work,
  i.e. 9.9-e).
- 21 value-mismatch (`got v128`) — defer to 9.9-d-7 audit.
- 3 small validator surfaces (BadBlockType / BadValType /
  NotImplemented).
- The remaining 9 likely cluster around assert_invalid /
  assert_trap shapes the runner partially supports.

**Next — 9.9-e**: v128 PARAM marshal + v128 local frame
layout per ADR-0046. Per-host work:
1. Frame layout: bump local-slot stride from 8 to 16 for
   v128 locals. arm64 `prologue.zig` + x86_64 `localDisp` /
   prologue both touch the slot computation.
2. Param marshal: incoming v128 params arrive in V0..V7
   (AAPCS64) / XMM0..XMM7 (SystemV); emit STR Q / MOVAPS to
   stash into the v128 local slot.
3. local.get / local.set / local.tee for v128: LDR Q / STR Q
   on arm64; MOVDQU on x86_64.
4. Edge fixtures + the simd_select.0 fixture flips PASS via
   the 9.9-d-5 emitV128Select path.

Subsequent §9.9 chunks per ADR-0045:
- 9.9-d-7: investigate residual 21 value-mismatches.
- 9.9-f: scale to FP arith + compares (heavy 9k+ files).
- 9.9-g: aggregate `test-spec-simd` into `test-all`; flip §9.9 [x].

After §9.9: §9.10 (smoke benches + gap analysis), §9.11
(audit + SHA backfill), §9.12 (open Phase 10).

## Open structural debt (pointers — full list in `.dev/debt.md`)

- **D-055** (x86_64 prologue inject) — blocked-by D-052 prologue
  extract.
- **D-057** (op_simd.zig hard-cap, now ~4442 LOC) — blocked-by
  ADR for source-split landing. Discharge requires ADR mirror
  of ADR-0030; deferred until §9.7 row close.
- 10 `blocked-by:` rows: D-007/D-010/D-016/D-018/D-020/D-021/
  D-022/D-026/D-028/D-052 — barriers all hold this resume.

Closed Phase 8b artefacts (preserved for Phase 12 + Phase 15)
live in git: ADRs 0035-0040, lessons in `.dev/lessons/INDEX.md`,
code in `src/ir/coalesce/`, regalloc.zig LIFO free-pool,
`src/engine/codegen/aot/`. `git log` is authoritative.

**Phase**: Phase 9 (SIMD-128, ADR-0041 — SSE4.2 baseline).
§9.5 [x] (ARM64 NEON pt 1), §9.6 [x] (ARM64 NEON pt 2),
§9.7 [x] (x86_64 SSE4.1+SSE4.2; 9.7-a..bb landed),
§9.8 [x] (scope absorbed per ADR-0044),
§9.9 in-flight (9.9-a..c + 9.9-d-1..6 landed; 9.9-e NEXT —
v128 PARAM marshal + v128 local frame layout per ADR-0046).
**Branch**: `zwasm-from-scratch`。
