# Session handover

> Read this at session start. **Replace** (not append) the `Current state`
> block + the `Active task` table at session end. Keep ≤ 100 lines.

## Next files to read on a cold start (in order)

1. `.dev/handover.md` (this file).
2. `.dev/ROADMAP.md` §9 Phase Status widget + §9.8 task table — Phase 8 active.
3. `.dev/debt.md` — D-054 + D-055 + 9 other rows.
4. `.dev/lessons/INDEX.md` — keyword-grep for the active task domain
   (focus: hoist-branch-targets-as-pc, regalloc, coalescer).
5. `.dev/decisions/0031_zir_hoist_pass.md` (D-053 root-cause amend per 8a.6).
6. `.dev/optimisation_log.md` (F/R/O ledger; 8b adoption discipline).

## Current state — Phase 9 / §9.6 [x] (full ARM64 NEON pt 2 closed); **§9.7 NEXT**

§9.6 fully closed at c12760cb. All sub-rows landed:
9.6-a/b/c-i/c-ii/d/e/f-i/f-ii/g-i/g-ii/g-iii/g-iv/g-v all `[x]`.
Final chunk (9.6-f-ii) discharged D-056 by implementing v128.const
+ i8x16.shuffle codegen via ADR-0042 hybrid const-pool with
post-emit fixup pass.

v1-audit done at 8cd953a7 (Phase 7 + Phase 8 clean; SIMD audit
informed ADR-0042). Future-Phase-15 refactors noted (encoder
consolidation, comptime walker verifier) — not debt, opportunistic.

Mac gates at last source commit: zone ✓, file_size ✓, spill ✓,
lint ✓; spec 212/0/20, wast 1158/0/0.

**§9.7 NEXT** — x86_64 SSE4.1 SIMD emit. Scope mirrors §9.5+§9.6's
ARM64 surface but on x86_64. SSE4.1 is the minimum baseline per
ADR-0041 §"5. SSE4.1 minimum baseline" (PMULLD / PINSRB-W-D /
PBLENDVB required).

Initial chunk plan (sub-rows TBD per Step 0 survey):
- 9.7-a: encoder foundation (XMM register pool, MOVDQA/MOVDQU
  load-store, basic XMM helpers).
- 9.7-b: shape-tag pipeline mirror (regalloc walker — already
  shared per ADR-0041, just needs handler wiring).
- 9.7-c onwards: parallel chunks to §9.5/§9.6 (lane access,
  binary arith, compares, narrow/extend, FP convert, trunc_sat,
  shuffle/swizzle via PSHUFB).

Step 0 mandatory for the first chunk — survey wasmtime/cranelift
x86_64 SIMD lowering + wasmer singlepass for SSE4.1 patterns.

After 8b.4: 8b.5 (boundary audit_scaffolding) + 8b.6 (open
§9.9 inline + flip Phase Status).

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

**Phase**: Phase 9 (SIMD-128, ADR-0041). §9.5 [x] (ARM64 NEON pt 1),
§9.6 [x] (ARM64 NEON pt 2), §9.7 NEXT (x86_64 SSE4.1).
**Branch**: `zwasm-from-scratch`。
