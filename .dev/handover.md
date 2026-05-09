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

## Current state — Phase 9 / §9.7 in-flight (9.7-a..ai landed); **9.7-aj NEXT**

9.7-ai: x86_64 i64x2.extmul × 4 (i32x4 → i64x2). 3-instr inline
recipe via PSHUFD imm 0x50/0xFA + PMULDQ (new SSE4.1) / PMULUDQ
(existing). 1 new encoder + 1 new helper. Closes the extmul
family across all three shapes (12 ops total). Total SIMD ops
handled: 176.

**9.7-aj NEXT** — i*x*.popcnt + i16x8.extadd_pairwise_*
(~3 ops, partially const-pool dependent). Per p9-9.7-af-survey:
`i8x16.popcnt` 7-instr SSSE3 PSHUFB-LUT (needs 1 const) or
9-instr Hacker's-Delight shift-add (no const). Without ADR-0042
const-pool, **inline-synth via shift-add is the path** — same
pattern as 9.7-u/v/w shift synthesis. `i16x8.extadd_pairwise_
i8x16_{s,u}` 1-instr each via PMADDUBSW (SSSE3) but needs a
±1 const lane mask (`0x0101...` for unsigned, `0x0101...`
multiplied differently for signed). Inline-synth via PCMPEQB
+ PSRLW imm 7 → 0x0101 broadcast. Bundle these 3 ops.

Subsequent: 9.7-ak (i32x4.extadd_pairwise_i16x8_{s,u} 2 ops,
similar pattern with 0x00010001 const synthesis), 9.7-al
(ADR-0042 const-pool plumbing + 4 deferred 9.7-ae u-variants +
i8x16.shuffle + v128.const). Phase 7 close-out pending.

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
§9.7 in-flight (x86_64 SSE4.1+SSE4.2; 9.7-a..ai landed; 9.7-aj NEXT).
**Branch**: `zwasm-from-scratch`。
