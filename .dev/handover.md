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

## Current state — Phase 9 / §9.7 in-flight (9.7-a..ap landed); **9.7-aq NEXT**

9.7-ap: x86_64 i32x4.trunc_sat_f64x2_u_zero (1 op, 7-instr
ROUNDPD+ADDPD-magic+SHUFPS-extract recipe + 2 consts; reuses
9.7-ao's 2^52 magic via extra_consts dedup). 1 new encoder
encShufps. Total SIMD ops handled: 185.

**9.7-aq NEXT** — `i32x4.extadd_pairwise_i16x8_u` (1 op, closes
extadd_pairwise family). Per cranelift `lower.isle:4032-4071`:
PMADDWD reads operands as signed i16, so for unsigned u16 lanes
we need sign-flip pre-correction. Recipe: XOR src with 0x8000
sign-flip mask (= u16 - 0x8000 → signed i16 in [-0x8000, 0x7FFF])
+ PMADDWD with all-1s (+1 per word) → produces (i16+i16) i32
sums + correction-add (+ 2*0x8000 = 0x10000 per pair = 65536
per i32) to recover the original u16+u16 sum. 4-5 instr + 2
consts (sign-flip XOR + correction add). Survey for cleanest
recipe shape.

Subsequent: 9.7-ar (i8x16.shuffle — needs derived a-mask/b-mask
plumbing extension; ADR-grade decision — either change lower
contract or fork extra_consts to per-fixup derived consts),
9.7-as (i32x4.trunc_sat_f32x4_u — needs 3 scratch xmms;
ADR-grade scratch-budget extension). Phase 7 close-out
approaching: ~2-3 chunks until 7.13 hard gate.

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
§9.7 in-flight (x86_64 SSE4.1+SSE4.2; 9.7-a..ap landed; 9.7-aq NEXT).
**Branch**: `zwasm-from-scratch`。
