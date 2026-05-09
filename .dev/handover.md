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

## Current state — Phase 9 / §9.7 in-flight (9.7-a..ab landed); **9.7-ac NEXT**

9.7-ab: x86_64 FP convert signed + promote/demote (4 ops).
4 new SSE2 encoders (CVTDQ2PS/CVTPS2PD/CVTPD2PS/CVTDQ2PD).
Single-instr unaries. Total SIMD ops handled: 147.

**9.7-ac NEXT** — i8x16.swizzle (1 op). Wasm semantics:
out[i] = idx[i] < 16 ? v[idx[i]] : 0. SSE PSHUFB control
byte: ctrl[i] high bit set → 0; else src[ctrl[i] & 0xF].
For idx in 16..127, PSHUFB would index into src (wrong;
Wasm wants 0). Cranelift uses PADDUSB(idx, 0x70-broadcast)
saturating-add to push 16..127 into 128..255 range (high
bit set). Without const-pool, synthesise the 0x70-broadcast
inline via PCMPEQB + PSRLW + PSHUFB-broadcast (similar to
9.7-v shift mask). 1 new encoder (PADDUSB) + ~10-12 instr
handler. ~150 src + ~50 test. No ADR.

Subsequent: 9.7-ad+ (FP unop family — abs/neg via PXOR
sign-mask synthesis; ceil/floor/trunc/nearest via ROUNDSS/
ROUNDPS imm; 9 ops), 9.7-ae+ (FP convert u-variants +
trunc-sat 6 ops via const-pool when ADR-0042 lands),
9.7-af+ (i8x16.shuffle const-pool dep), 9.7-ag (v128.const
+ const-pool finalisation).

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
§9.7 in-flight (x86_64 SSE4.1+SSE4.2; 9.7-a..ab landed; 9.7-ac NEXT).
**Branch**: `zwasm-from-scratch`。
