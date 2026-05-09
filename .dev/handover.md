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

## Current state — Phase 9 / §9.7 in-flight (9.7-a..ar landed); **D-054 SPIKE FOLLOW-UP NEXT**

9.7-ar: x86_64 i8x16.shuffle via emit-time derived a-mask/b-mask
+ PSHUFB-pair + POR-merge (1 op, 7-instr recipe). Closes the
structural blocker from 9.7-al/am. Total SIMD ops handled: 187.

**SIDE-FINDING (this cycle)**: spike confirmed D-054 OrbStack
as-loop-broke FAIL is a HOIST PASS BUG (NOT Rosetta artefact) —
`ZWASM_NO_HOIST=1` makes OrbStack 212/0/20 green. Likely a
synthetic-local lifetime / SysV-caller-saved-reg interaction
around `call $dummy`. Updated D-054 with concrete discharge plan.

**9.7-as NEXT** — D-054 root-cause investigation + fix. The
hypothesis (synthetic-local clobbered by SysV caller-saved-reg
spill discipline around calls) is testable via WAT spike +
lldb -b on OrbStack. Discharge order: (a) WAT replicate of
the bug shape (loop-with-call-with-br-const) lands as edge-
case fixture; (b) lldb -b inspects synthetic-local lifetime
across call boundary; (c) fix in `src/ir/hoist/pass.zig` or
regalloc spill discipline; (d) D-054 closes; OrbStack gate
becomes strict (no D-054 carry).

Subsequent: 9.7-at (i32x4.trunc_sat_f32x4_u — needs 3 scratch
xmms; ADR-grade scratch-budget extension OR fall back to
spilling tmp to stack). Phase 7 close-out approaching:
~1-2 chunks + D-054 fix until 7.13 hard gate.

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
§9.7 in-flight (x86_64 SSE4.1+SSE4.2; 9.7-a..ar landed; D-054 fix or 9.7-as NEXT).
**Branch**: `zwasm-from-scratch`。
