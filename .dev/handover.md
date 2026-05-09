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

## Current state — Phase 9 / §9.7 in-flight (9.7-a..aj landed); **9.7-ak NEXT**

9.7-aj: x86_64 i16x8.extadd_pairwise_i8x16 × 2 via inline 0x01-
per-byte mask synth + PMADDUBSW. 1 new encoder, 2 new ZirOp
entries. Total SIMD ops handled: 178.

**9.7-ak NEXT** — i32x4.extadd_pairwise_i16x8_{s,u} (2 ops).
Different mask: needs 0x00010001-per-dword (= +1 per i16 lane).
Recipe per cranelift: PMADDWD (SSE2, already from 9.7-af) takes
two i16-pair operands and dot-products into i32. With +1-per-i16-
lane as one operand, this reduces to pairwise i16+i16 → i32
addition. The 0x0001-per-i16 mask is harder to synth inline — try
PCMPEQB ones + PSRLW imm 15 → 0x0001 per word ✓. Recipe ~4 instr.
Both ops use same shape (PMADDWD doesn't have signed/unsigned
variants — i16 is always signed in PMADDWD); `_u` of Wasm
extadd_pairwise needs additional zero-extend prep (e.g. PMADDWD
of (zero-extended u16 lanes) doesn't compose cleanly without
helper). Survey to confirm; may split _s and _u into separate
chunks.

Subsequent: 9.7-al (i8x16.popcnt — inline-synth via PSHUFB-LUT
with const-pool, OR Hacker's-Delight shift-add ~9 instr), 9.7-am
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
§9.7 in-flight (x86_64 SSE4.1+SSE4.2; 9.7-a..aj landed; 9.7-ak NEXT).
**Branch**: `zwasm-from-scratch`。
