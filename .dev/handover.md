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

## Current state — Phase 9 / §9.7 in-flight (9.7-a..al landed); **9.7-am NEXT**

9.7-al: x86_64 ADR-0042 const-pool port + v128.const (mirror of
9.6-f-ii ARM64 work). New SimdConstFixup struct + post-emit pool
append/patch loop + MOVUPS-RIP-rel encoder. Total SIMD ops
handled: 180.

**9.7-am NEXT** — i8x16.shuffle (1 op, leverages 9.7-al
const-pool foundation). Recipe: load shuffle mask from
const-pool via the new MOVUPS-RIP-rel placeholder, then PSHUFB
(SSSE3) — but PSHUFB has different semantics from ARM64's TBL
(no fallthrough zeroing on idx ≥ 16; PSHUFB zeros lanes only
when bit 7 is set). Cranelift's recipe handles this via
`PSHUFB(src1, mask) | PSHUFB(src2, mask XOR 0x10)` for the
2-register shuffle case. Survey to pin the exact recipe; ~6-8
instr including const-pool load + the synthesis. ZirFunc.
simd_consts entry for the shuffle mask is populated by lower.

Subsequent: 9.7-an (i8x16.popcnt with const-pool — 7-instr
SSSE3 PSHUFB-LUT recipe, 1 const), 9.7-ao (4 deferred 9.7-ae
u-variants — f64x2.convert_low_i32x4_u + 3 trunc_sat u-
variants, all using const-pool float magic numbers), 9.7-ap
(i32x4.extadd_pairwise_i16x8_u + miscellaneous remaining
const-pool ops). Phase 7 close-out approaching.

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
§9.7 in-flight (x86_64 SSE4.1+SSE4.2; 9.7-a..al landed; 9.7-am NEXT).
**Branch**: `zwasm-from-scratch`。
