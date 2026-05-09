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

## Current state — Phase 9 / §9.7 in-flight (9.7-a..q landed); **9.7-r NEXT**

9.7-q: x86_64 f32x4/f64x2 min/max via NaN-correction
synthesis (4 ops). 11 new encoders (MIN/MAX PS+PD;
OR/XOR/ANDN PS+PD; PSRLD imm via opcode-parametric
encSsePackedShiftImmGroup). 2 helpers (emitV128FpMin 10
instr, emitV128FpMax 13 instr) per cranelift
`lower.isle:2783-2939`. XMM14/XMM15 scratch. Total SIMD
ops handled: 92.

**9.7-r NEXT** — v128 bitwise ops + select (8 ops):
v128.{not, and, or, xor, andnot, bitselect, any_true,
all_true}. Encoders mostly exist (ORPS/XORPS/ANDNPS from
9.7-q; PXOR from 9.7-h; need PAND, PANDN-as-PXOR-then-AND
or use existing ANDNPS, PBLENDVB for bitselect SSE4.1).
Wasm `v128.bitselect(c, a, b)` = `(a & c) | (b & ~c)` —
2-3 instr via PAND/PANDN/POR or use PBLENDVB-with-mask.
any_true: PTEST + SETcc (SSE4.1) — pop v128, push i32.
all_true: PCMPEQB + PMOVMSKB + AND-mask + SETcc shape.
Likely: 3-4 new encoders (PAND, PANDN-int, PTEST,
PMOVMSKB) + 6 binary wrappers + 2 reduction handlers
(any_true / all_true with i32 result). ~200 src + ~100
test. No ADR.

Subsequent: 9.7-s+ (i*x* shifts shl/shr_s/shr_u; abs/neg
via PXOR sign-mask const-pool), 9.7-t+ (conversion +
narrow/extend + shuffle PSHUFB), 9.7-u (v128.const via
ADR-0042 const-pool finalisation).

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
§9.7 in-flight (x86_64 SSE4.1+SSE4.2; 9.7-a..q landed; 9.7-r NEXT).
**Branch**: `zwasm-from-scratch`。
