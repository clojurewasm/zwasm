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

## Current state — Phase 9 / §9.7 in-flight (9.7-a..ah landed); **9.7-ai NEXT**

9.7-ah: x86_64 i32x4.extmul × 4 (i16x8 → i32x4). Same shape as
9.7-ag with PMOVSXWD/PMOVZXWD + PMULLD substituted; helpers
reused unchanged. No new encoders. Total SIMD ops handled: 172.

**9.7-ai NEXT** — i64x2.extmul_{low,high}_i32x4_{s,u} (4 ops).
Different multiply semantics from i16x8/i32x4 extmul: PMULDQ
(SSE4.1) for signed and PMULUDQ (SSE2) for unsigned both take
unwidened i32 inputs in even-numbered lanes and produce i64
outputs — so they DON'T need a separate extend step. Recipe per
cranelift: PSHUFD imm=0x{50/F5} to position lanes (low: even
positions; high: odd from upper 64 → even positions), then
PMULDQ/PMULUDQ. 2-3 instr per op. May need a separate
emitV128I64x2Extmul helper (different from 9.7-ag's
emitV128IntExtmul). Both encoders already exist (PMULDQ from
9.7-c-?, PMULUDQ from 9.7-d). 1 new encoder needed if PMULDQ
absent; check before survey.

Subsequent: 9.7-aj (ADR-0042 const-pool + popcnt + 4
extadd_pairwise + 4 deferred 9.7-ae u-variants + i8x16.shuffle
+ v128.const). Phase 7 close-out pending.

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
§9.7 in-flight (x86_64 SSE4.1+SSE4.2; 9.7-a..ah landed; 9.7-ai NEXT).
**Branch**: `zwasm-from-scratch`。
