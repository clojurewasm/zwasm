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

## Current state — Phase 9 / §9.7 in-flight (9.7-a..ba landed); **9.7-bb v128.load*x*_s/u extending NEXT**

9.7-ba: 8 ops (commit `21ae2170`) — v128.load_lane / store_lane
× {8,16,32,64}. memarg + 1-byte lane immediate (sub-opcodes
84..91). Validator path replaced binop catch-all with proper
opSimdLoadLane / opSimdStoreLane helpers. Lower path:
emitMemargLane packs offset + lane (align dropped). Emit path:
2 parametric helpers (load + merge via PINSR; PEXTR + store
with PUSH/POP RCX). No new encoders. 231 SIMD ops handled
total. 3-host green.

**Next — 9.7-bb**: v128.load{8x8,16x4,32x2}_{s,u} (6 ops).
Extending loads — load 8 bytes into low qword, sign/zero-extend
each lane to the next-larger size (8→16, 16→32, 32→64).
Recipe per cranelift `lower.isle:4977-5010`:
- load8x8_s: MOVQ xmm, [mem]; PMOVSXBW xmm — extend low 8 i8
  lanes to 8 i16.
- load8x8_u: MOVQ xmm, [mem]; PMOVZXBW xmm.
- load16x4_s/u: MOVQ + PMOVSX/ZXWD.
- load32x2_s/u: MOVQ + PMOVSX/ZXDQ.

Encoders: PMOVSX/ZX{BW,WD,DQ} all exist from 9.7-x. Need MOVQ
xmm, m64 mem-form encoder OR reuse existing MOVSD memory-load
(both produce xmm with low qword loaded + upper zeroed; PMOVSX/ZX
only reads low qword anyway). Plan: reuse MOVSD via existing
encMovssMovsdMemBaseIdx, no new encoders.

Sub-chunks remaining:
- 9.7-bb: load*x*_s/u extending × 6

After this, §9.7 row scope is exhausted: all v128 ZirOps from
zir.zig:184-288 have x86_64 emit handlers. §9.7 row + §9.8 row
(overlapping scope) close together via §18 ADR or scope merge.
Then §9.9/9.10/9.11/9.12 close-out.

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
§9.7 in-flight (x86_64 SSE4.1+SSE4.2; 9.7-a..ba landed; 9.7-bb
NEXT; 6 v128 memory ops still unhandled before §9.7 close).
**Branch**: `zwasm-from-scratch`。
