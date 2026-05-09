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

## Current state — Phase 9 / §9.7 in-flight (9.7-a..am landed); **9.7-an NEXT**

9.7-am: x86_64 i32x4.trunc_sat_f64x2_s_zero (1 op, 6-instr
recipe + 1 const). Added per-emit-pass extra_consts machinery
to const-pool plumbing (shared static consts distinct from
func.simd_consts per-instance literals). 1 new encoder
encCvttpd2dq. Total SIMD ops handled: 181.

**9.7-an NEXT** — i32x4.trunc_sat_f64x2_u_zero (1 op). Same
shape as 9.7-am with different magic constants per cranelift
`lower.isle:5069-5093`: 6-instr recipe + 2 consts (UINT_MAX
upper clamp + 0x1.0p+52 IEEE-754 mantissa-trick offset).
Alternative path: ROUNDPD imm + MINPD-with-uint-max + the
mantissa-trick. Recipe pre-condition: src must be ≥ 0 (lower
the negatives to 0 first via MAXPD-zero). Bundle with: i8x16.
popcnt (1 op via SSSE3 PSHUFB-LUT, 1 const) since both use
the new extra_consts machinery and have similar shape.
Possibly also bundle f64x2.convert_low_i32x4_u (1 op, 2 consts)
which uses the same 0x1.0p+52 mantissa magic.

Subsequent: 9.7-ao (i8x16.shuffle — needs derived a-mask/b-mask
plumbing extension), 9.7-ap (i32x4.trunc_sat_f32x4_u — needs
3 scratch xmms; survey for fork to "load const into vreg-pool
via spill" or accept ADR-grade scratch budget extension),
9.7-aq (remaining misc + i32x4.extadd_pairwise_i16x8_u). Phase
7 close-out approaching.

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
§9.7 in-flight (x86_64 SSE4.1+SSE4.2; 9.7-a..am landed; 9.7-an NEXT).
**Branch**: `zwasm-from-scratch`。
