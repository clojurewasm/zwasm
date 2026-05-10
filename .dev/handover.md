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

## Current state — Phase 9 / §9.7 in-flight (9.7-a..au landed); **9.7-av FP pmin/pmax NEXT**

9.7-au: 22 ops bundled (commit `865b7517`) — int min/max ×12
(i8x16/i16x8/i32x4 × {min_s,min_u,max_s,max_u}) + sat arith
×8 (i8x16/i16x8 × {add_sat,sub_sat} × {s,u}) + avgr_u ×2.
15 new encoders (signed min/max + signed/unsigned sat arith +
avgr); unsigned min/max encoders reused from 9.7-n. All
single-instruction native SSE2/SSE4.1; wrappers dispatch
through 9.7-b's emitV128IntBinop unchanged. 210 SIMD ops
handled total. 3-host green.

**Next — 9.7-av**: f32x4/f64x2 .pmin/pmax (4 ops). pseudo-min/
max with src2-on-equal-magnitude semantics (NaN-propagating
src2 if either NaN). Cranelift recipe (`lower.isle` F32X4/
F64X2 fpmin/fpmax) is structurally distinct from native
MINPS/MAXPS — uses CMP-LT or CMP-LE to derive a per-lane mask
then BLEND/AND the inputs. ARM64 mirror landed at 9.6-c-ii
via FCMGT + BSL. x86 likely needs MINPS/MAXPS + ANDPS/ORPS
synthesis (~5-7 instr). Single-chunk bundle.

After 9.7-av: 9.7-aw (i64x2.extract_lane, 1 op via PEXTRQ,
trivial), then 9.7-ax+ for v128 memory ops (load/store/
load_lane/store_lane/splat/zero/extending — 22 ops, larger
structural chunk needing memory-addressing + alignment
encoding). Once those land, §9.7 row + §9.8 row (overlapping
scope) close together via §18 ADR or scope merge.

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
§9.7 in-flight (x86_64 SSE4.1+SSE4.2; 9.7-a..au landed; 9.7-av
NEXT; ~27 SIMD ops still unhandled before §9.7 close).
**Branch**: `zwasm-from-scratch`。
