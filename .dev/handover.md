# Session handover

> Read this at session start. **Replace** (not append) the `Current state`
> block + the `Active task` table at session end. Keep the whole file
> ≤ 100 lines — anything older than the active task lives in `git log`.
> Authoritative plan is `.dev/ROADMAP.md`; stable file shape lives in
> `CLAUDE.md` "Layout".

## Next 3 files to read (cold-start order)

1. `.dev/handover.md` (this file).
2. `.dev/ROADMAP.md` — read the **Phase Status** widget at the top
   of §9 to find the IN-PROGRESS phase, then its expanded `§9.<N>`
   task list; pick up the first `[ ]` task.
3. The most recent `.dev/decisions/NNNN_*.md` ADR (if any) — to
   recover load-bearing deviations in flight.

## Current state

- **Phase**: **Phase 7 IN-PROGRESS** (JIT v1 ARM64 baseline).
- **Last commit**: `b336e78` — §9.7 / 7.0 land: `src/jit/reg_class.zig`
  with full `RegClass` set (gpr / fpr / simd + 3 `*_special`)
  + RegClassInfo lookup table; zone discipline kept zir.RegClass
  in Zone 1, RegClassInfo in Zone 2. All three hosts green.
- **Next task**: §9.7 / 7.1 — `src/jit/regalloc.zig` greedy-local
  allocator with `regalloc.verify(zir)` post-condition.
- **Branch**: `zwasm-from-scratch`, pushed to `origin/zwasm-from-scratch`.
  `main` is forbidden; `--force` is forbidden.

## Active task — §9.7 / 7.1 (greedy-local regalloc + verify)

Per ROADMAP §9.7 exit criterion #1: `src/jit/regalloc.zig`
greedy-local allocator; `regalloc.verify(zir)` runs as a post-
condition after every alloc.

Phase-7 / 7.1 scope: stand up the data shape + a minimal greedy-
local pass that operates on `ZirFunc.liveness` (already populated
by §9.5 / 5.4) plus `ZirFunc.reg_class_hints` (the slot reserved
in zir.ZirFunc since day 1 per §4.2). Real per-arch register
assignment lands in §9.7 / 7.2 + 7.3 — this task delivers the
allocator algorithm + the verify post-condition catching its
invariants (every vreg has a class assignment; live ranges
don't share a slot; etc.).

Plan:

1. Survey W54 post-mortem + regalloc2 (Cranelift) for the
   greedy-local idiom — mandatory per `textbook_survey.md`
   Guard 4 (regalloc-touching).
2. Define `Allocation` shape (per-vreg → physical slot index,
   with class-aware spill fallback). Use `RegClassInfo` from
   §9.7 / 7.0 for spill-slot stride.
3. `compute(allocator, *ZirFunc) !Allocation` walks live ranges
   in order, assigns the first free slot in the requested class.
   `verify(*const ZirFunc, *const Allocation) !void` checks:
   (a) every defined vreg has an assignment; (b) overlapping
   live ranges never share the same physical slot; (c) class
   assignment matches RegClassInfo (no FPR slot for a GPR vreg).
4. Tests: simple straight-line case (3 vregs, 3 slots);
   overlap case (2 simultaneously-live, must use 2 distinct
   slots); class-mismatch case (verify rejects a forced bad
   assignment).
5. Three-host `zig build test-all`.

Phase-7 outstanding (post 7.1): 7.2 jit_arm64 inst+abi /
7.3 jit_arm64 emit / 7.4 spec test pass=fail=skip=0 via JIT /
7.5 40+ realworld via JIT / 7.6 `interp == jit_arm64`
differential / 7.7 wasmtime stdout diff (ADR-0010 deferred-in)
/ 7.8 ClojureWasm (ADR-0010 deferred-in) / 7.9 boundary audit
/ 7.10 phase tracker.

Carry-overs queued:
- §9.5: `no_hidden_allocations` zlinter (ADR-0009); validator.zig
  per-feature split (with §9.1 / 1.7); liveness control-flow +
  memory-op coverage (drives directly here in 7.1+); const-prop
  per-block (Phase-15); `sections.zig` (1073) soft-cap split.
- §9.6: `br-table-fuzzbug` multi-param `loop`; 10 SKIP-VALIDATOR
  realworld; 39 trap-mid-exec fixtures (debugged in §9.7 / 7.6).

## Outstanding spec gaps (queued for Phase 6 — v1 conformance)

These were surfaced during Phases 2–4 and deferred from their own
phase. Phase 6 (ADR-0008) absorbs them as part of the v1
conformance baseline; do NOT re-pick during Phase 5.

- **multivalue blocks (multi-param)**: `BlockType` needs to carry
  both params + results; `pushFrame` must consume params (Phase 2
  chunk 3b carry-over).
- **element-section forms 2 / 4-7**: explicit-tableidx and
  expression-list variants (Phase 2 chunk 5d-3).
- **ref.func declaration-scope**: §5.4.1.4 strict declaration-
  scope check (Phase 2 chunk 5e).
- **Wasm-2.0 corpus expansion**: 47 of 97 upstream `.wast` files
  deferred (block / loop / if 1-5, global 24, data 20, ref_*,
  return_call*) — each surfaces a specific validator gap.

## Open questions / blockers

(none — push to `origin/zwasm-from-scratch` is autonomous inside
the `/continue` loop per the skill's "Push policy"; no user
approval required.)
