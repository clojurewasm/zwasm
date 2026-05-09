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

## Current state — Phase 9 / §9.7 in-flight (9.7-a..m landed); **9.7-n NEXT**

9.7-m: i64x2 signed compares lt_s/gt_s/le_s/ge_s (4 ops). New
encoder encPcmpgtQ (SSE4.2 66 0F 38 37 /r); reuses 9.7-l's
`emitV128IntCmpSigned(encoder_gt, kind)` helper unchanged with
the new encoder threaded as the `gt` primitive. ADR-0041 §5
amended (Revision history row appended) — x86_64 baseline
raised SSE4.1 → SSE4.2; Alternative E (SSE4.1 9-instr
synthesis from cranelift `inst.isle:3179-3191`) added with
rejection rationale; CPUID detection bumps from bit 19 to
bit 20. Total SIMD ops handled: 54.

**9.7-n NEXT** — unsigned compares ult/ugt/ule/uge for
8/16/32-bit shapes (12 ops; i64x2 unsigned not in spec).
Cranelift's preferred path is PMINU/PMAXU + PCMPEQ (rule 1 in
`lower.isle:2016-2080`):
- ugt(a,b): PMAXU(a,b) → max; PCMPEQ(max,b); PXOR all-ones
- ult(a,b): PMINU(a,b) → min; PCMPEQ(min,b); PXOR all-ones
- uge(a,b): PMAXU(a,b) → max; PCMPEQ(a,max)  (2 instr)
- ule(a,b): PMINU(a,b) → min; PCMPEQ(a,min)  (2 instr)

PMAXU/PMINU coverage: PMAXUB / PMINUB are SSE2; PMAXUW / PMINUW
/ PMAXUD / PMINUD are SSE4.1 — all on baseline. 6 new encoders
+ 1 new helper `emitV128IntCmpUnsigned` + 12 1-line wrappers.
LOC estimate ~170 src + ~200 test. No ADR needed.

Subsequent: 9.7-o+ (FP compare CMPPS/PD), 9.7-p+ (FP arith),
9.7-q+ (bitwise ops + select), 9.7-r+ (conversion +
narrow/extend + shuffle PSHUFB), 9.7-s (v128.const via
ADR-0042 const-pool).

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
§9.7 in-flight (x86_64 SSE4.1+SSE4.2; 9.7-a..m landed; 9.7-n NEXT).
**Branch**: `zwasm-from-scratch`。
