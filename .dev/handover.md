# Session handover

> Read this at session start. **Replace** (not append) the `Current state`
> block + the `Active task` table at session end. Keep the whole file
> ≤ 100 lines — anything older than the active task lives in `git log`.
> Authoritative plan is `.dev/ROADMAP.md`; stable file shape lives in
> `CLAUDE.md` "Layout".

## Next 3 files to read (cold-start order)

1. `.dev/handover.md` (this file).
2. `.dev/decisions/0014_redesign_and_refactoring_before_phase7.md` —
   redesign + refactoring sweep that lands inside Phase 6 before
   close. Defines work-item block §9.6 / 6.K (Value funcref,
   ownership model, cross-module imports, element forms 5/7,
   Label arity formalisation, partial-init re-measure).
3. `.dev/decisions/0012_first_principles_test_bench_redesign.md` —
   Phase 6 reopen scope (work items 6.A〜6.J, DAG, deferred
   items; 6.K is appended per ADR-0014 §18 amendment).

## Current state

- **Phase**: **Phase 6 IN-PROGRESS** (6.A〜6.D + 6.K.1 done;
  6.K.2〜6.K.6 + 6.E + 6.F〜6.J pending).
- **Last source commit**: `296d78e` — feat(p6) §9.6 / 6.K.1 land
  `Value.ref` → `*FuncEntity` pointer encoding + null_ref=0 atomic
  migration. Three-host green. `test-wasmtime-misc-runtime`
  242/29 byte-identical to baseline (handover's prior "28" was
  off-by-one); no regression. The 29 fails resolve through 6.K.2
  ownership model + 6.K.3 cross-module dispatch.
- **ADR-0014 (Accepted)**: redesign + refactoring sweep before
  Phase 7. §9.6 / 6.K is the work-item block; no follow-up ADR.
- **Branch**: `zwasm-from-scratch`, pushed.

## Active task — §9.6 / 6.K.2 (single-allocator Runtime + Instance back-ref)

`test-wasmtime-misc-runtime` standing at **242 / 29** post-6.K.1
(unchanged — 6.K.1 was an encoding migration; the remaining fails
all involve cross-module routing or partial-init re-measure that
6.K.2/6.K.3/6.K.6 carry).

| #     | Description                                                                          | Status         |
|-------|--------------------------------------------------------------------------------------|----------------|
| 6.K.1 | `Value.ref` → `*FuncEntity` pointer encoding                                         | [x] 296d78e    |
| 6.K.2 | Single-allocator Runtime + Instance back-ref; drop `memory_borrowed`                 | [ ] **NEXT**   |
| 6.K.3 | Cross-module imports for table / global / func (after 6.K.1 + 6.K.2)                 | [ ]            |
| 6.K.4 | `decodeElement` forms 5 / 6 / 7 (parallel)                                           | [ ]            |
| 6.K.5 | Label arity formalisation + `single_slot_dual_meaning.md` + §14 entry (parallel)     | [ ]            |
| 6.K.6 | Re-measure `partial-init-table-segment/indirect-call` after 6.K.1–6.K.3              | [ ]            |

After 6.K all-`[x]`, 6.E re-measures (the 29 fails flow through),
then 6.F / 6.G / 6.H, with 6.I in parallel, then 6.J strict close.

Step 0 brief for 6.K.2 should target `src/interp/mod.zig`
(`Runtime.alloc` / `memory_borrowed` field — drop), and `src/c_api/instance.zig`
(`instantiateRuntime` allocator threading: arena vs parent_alloc
split; the cross-module memory-borrow path at iter 7 that
introduces `memory_borrowed`). ADR-0014 §2.1 / 6.K.2's "Files
touched" lists Runtime + Instance struct shape + the elem-segment
loader (parent_alloc vs arena ambiguity surveyed in
`p6-6K1-survey.md` §3 "Allocator ownership chain").

Per-row TDD loop unchanged (Step 0 Survey → Plan → Red → Green →
Refactor → three-host test gate → source commit → handover +
push + re-arm). Per ROADMAP §9.6 / 6.J the close is **strict 100%
PASS**; the only permitted defer is a v1-era design-dependent
fixture documented in `.dev/decisions/skip_<fixture>.md` AND
physically removed / `# DEFER:`-marked from the active manifest so
the runner's tally is genuinely zero.

## Phase 6 close → Phase 7 (JIT v1 ARM64) — direct transition

ADR-0014 cancels the placeholder "post-Phase-6 refactor phase"
wiring. Phase 7 is unchanged (JIT v1 ARM64 baseline), no
renumber, no follow-up ADR. The `continue` skill's standard
§9.<N> → §9.<N+1> phase boundary handler applies as-is once
6.K + 6.E + 6.F / 6.G / 6.H / 6.I + 6.J all `[x]`.

## Phase 6 reopen DAG (ADR-0012 §6 + ADR-0014 §2.1)

```
6.A ✅  6.B ✅  6.C ✅  6.D ✅
 │
 ├─→ 6.E ⏳ (28 fails; resolves through 6.K)
 │    │
 │    ├─→ 6.K.1 ─→ 6.K.2 ─→ 6.K.3 ─→ 6.K.6
 │    ├─→ 6.K.4   (parallel)
 │    └─→ 6.K.5   (parallel)
 │           │
 │           └─→ {6.F, 6.G, 6.H} → 6.J → §9.7 (JIT v1 ARM64)
 │
 └─→ 6.I (parallel)  ─→ 6.J
```

## Outstanding spec gaps (Phase 6 absorbs)

- multivalue blocks (multi-param) — Phase 2 chunk 3b carry-over;
  loop-with-params closes alongside 6.K.5 once a multi-param
  fixture lands
- element-section forms 2 / 5 / 6 / 7 — closes at 6.K.4
- ref.func declaration-scope — Phase 2 chunk 5e (independent of
  6.K)
- 13 wasmtime_misc BATCH1-3 fixtures queued (validator gaps)
- 39 trap-mid-execution realworld fixtures — covered through
  6.E + 6.K.3 cross-module wiring
- 10 SKIP-VALIDATOR realworld fixtures
- 28 wasmtime_misc runtime-runner failures (resolved through
  6.K per ADR-0014 §2.1)

## Open questions / blockers

(none — autonomous loop continues 6.K.1 → 6.K.6 → 6.E re-run →
6.F / 6.G / 6.H / 6.I → 6.J. No follow-up ADR after 6.J close.)
