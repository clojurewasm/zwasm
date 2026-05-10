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

## Current state — Phase 9 / §9.7 in-flight (9.7-a..aw landed); **9.7-ax v128 memory ops NEXT**

9.7-aw: 1 op (commit `67333cf1`) — i64x2.extract_lane via
PEXTRQ (SSE4.1 REX.W=1 variant of PEXTRD). New encoder
encPextrQ + handler mirror 9.7-e's i32x4 counterpart with u1
lane. windowsmini D-028 flake fired once (`test runner failed
to respond for 1m1.34ms`); retry passed per documented
workaround. 215 SIMD ops handled total. 3-host green.

**Next — 9.7-ax**: v128 memory ops (~22 ops). Significant new
infra needed:
- Memory-addressing encoders for v128 — MOVUPS / MOVAPS xmm,
  m128 (load/store), MOVD/Q xmm, m32/m64 (load*_zero), MOVSS/
  MOVSD memory forms (load*_splat lane=0).
- ModR/M with SIB + disp encoding (the existing rbpDisp helpers
  cover RBP-relative; v128 mem ops need full memarg base+offset
  with R15 = guest memory base register).
- ZirOp payload that carries memarg (offset + align). Currently
  the SIMD lower path handles this for non-v128 mem ops; need
  to thread through for the v128 variants.
- Bounds check via existing trap stub.

Sub-chunks likely:
- 9.7-ax: v128.load + v128.store (2 ops, foundation, defines
  the memarg pattern + addressing helper).
- 9.7-ay: load_splat × 4 (load8/16/32/64 splat).
- 9.7-az: load*_zero × 2 (load32/64 zero).
- 9.7-ba: load_lane / store_lane × 8 (load/store 8/16/32/64).
- 9.7-bb: load*x*_s/u extending loads × 6 (8x8/16x4/32x2 × s/u).

Once those land, §9.7 row + §9.8 row (overlapping scope)
close together via §18 ADR or scope merge.

Subsequent: §9.9 (simd.wast wired in, fail=skip=0), §9.10
(smoke benches + gap analysis), §9.11 (audit + SHA backfill),
§9.12 (open Phase 10).

## Open structural debt (pointers — full list in `.dev/debt.md`)

- **D-055** (x86_64 prologue inject) — blocked-by D-052 prologue
  extract.
- **D-057** (op_simd.zig hard-cap, now ~4070 LOC) — blocked-by
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
§9.7 in-flight (x86_64 SSE4.1+SSE4.2; 9.7-a..aw landed; 9.7-ax
NEXT; ~22 v128 memory ops still unhandled before §9.7 close).
**Branch**: `zwasm-from-scratch`。
