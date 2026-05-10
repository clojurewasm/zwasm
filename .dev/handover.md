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

## Current state — Phase 9 / §9.7 in-flight (9.7-a..ay landed); **9.7-az v128.load{32,64}_zero NEXT**

9.7-ay: 4 ops (commit `1241e3b1`) — v128.load{8,16,32,64}_splat.
All reuse 9.7-ax's v128MemPrologue with access_size 1/2/4/8 +
per-lane-width broadcast tail. No new encoders. 8/16-bit GPR
roundtrip (MOVZX + MOVD + broadcast); 32/64-bit MOVSS/MOVSD
direct (zero-extending mem load) + PSHUFD broadcast. 221 SIMD
ops handled total. 3-host green.

**Next — 9.7-az**: v128.load{32,64}_zero (2 ops). Load 4 or 8
bytes into low lane(s); upper bytes zero. The load semantics
match exactly what MOVSS/MOVSD already do (32-bit zero-extends
upper 96; 64-bit zero-extends upper 64). So:
- load32_zero: MOVSS dst, [mem] — single instruction.
- load64_zero: MOVSD dst, [mem] — single instruction.

Even simpler than load_splat — no broadcast tail needed.

Sub-chunks remaining:
- 9.7-az: load*_zero × 2
- 9.7-ba: load_lane / store_lane × 8 (load/store 8/16/32/64)
- 9.7-bb: load*x*_s/u extending loads × 6

After those, ~16 ops total then §9.7 row + §9.8 row
(overlapping scope) close together via §18 ADR or scope merge.

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
§9.7 in-flight (x86_64 SSE4.1+SSE4.2; 9.7-a..ay landed; 9.7-az
NEXT; ~16 v128 memory ops still unhandled before §9.7 close).
**Branch**: `zwasm-from-scratch`。
