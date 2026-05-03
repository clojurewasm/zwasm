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

- **Phase**: **Phase 6 IN-PROGRESS** (6.A〜6.D done, 6.E paused
  on 28 fails; 6.F〜6.J pending; 6.K just opened per ADR-0014).
- **Last source commit**: `7b26760` — fix(p6) §9.6 / 6.E iter 11
  split Label arity (br vs end), wire defined globals. Three-host
  green. The underflow's true cause was `loopOp` hardcoding
  `arity=0` for both end and br paths (`tinygo_fib`'s
  `loop (result i32)`).
- **ADR-0014 (Accepted)**: redesign + refactoring sweep before
  Phase 7. Adds §9.6 / 6.K with six work items that unblock the
  remaining 27 cross-module fails by re-deriving funcref
  semantics + the ownership model, instead of patching around
  them. No follow-up ADR; everything stays in Phase 6.
- **Branch**: `zwasm-from-scratch`, pushed.

## Active task — §9.6 / 6.K.1 (first concrete next step)

`test-wasmtime-misc-runtime` baseline: **242 / 28** (trail
78 → 65 → 45 → 41 → 39 → 30 → 29 → 28 across iter 5–11). The
remaining 28 share one root: v1 carry-over of single-instance-
implicit semantics. ADR-0014 resolves them through six work
items inside Phase 6 (no Phase 7 deferral, no follow-up ADR).
DAG / per-row scope / acceptance live in ADR-0014 §2.1; this
table tracks status only.

| #     | Description                                                                          | Status         |
|-------|--------------------------------------------------------------------------------------|----------------|
| 6.K.1 | `Value.ref` → `*FuncEntity` pointer encoding                                         | [ ] **NEXT**   |
| 6.K.2 | Single-allocator Runtime + Instance back-ref; drop `memory_borrowed`                 | [ ]            |
| 6.K.3 | Cross-module imports for table / global / func (after 6.K.1 + 6.K.2)                 | [ ]            |
| 6.K.4 | `decodeElement` forms 5 / 6 / 7 (parallel)                                           | [ ]            |
| 6.K.5 | Label arity formalisation + `single_slot_dual_meaning.md` + §14 entry (parallel)     | [ ]            |
| 6.K.6 | Re-measure `partial-init-table-segment/indirect-call` after 6.K.1–6.K.3              | [ ]            |

ROADMAP §9.6 reopened-scope table inlines 6.K.1〜6.K.6 between
6.D and 6.E (so the `continue` skill picks 6.K.1 as the first
`[ ]` row). After 6.K all-`[x]`, 6.E re-measures (the 28 fails
flow through), then 6.F / 6.G / 6.H, with 6.I in parallel,
then 6.J strict close.

Per-row TDD loop matches the rest of Phase 6 (Step 0 Survey
subagent over Value/funcref design space → Plan → Red → Green →
Refactor → three-host test gate → source commit → handover +
push + re-arm). Step 0 brief for 6.K.1 should target
`src/interp/{mod,mvp.zig,ext_2_0/{ref_types,table_ops}.zig}`,
`src/c_api/instance.zig` (FuncEntity allocation in
`instantiateRuntime`), and the 70+ test sites in
`interp/ext_2_0/table_ops.zig` + `interp/trap_audit.zig` per
ADR-0014 §2.1 / 6.K.1's "Files touched" list.

Sequence: pick one cluster per iteration, fix root cause, re-run,
move fixtures from FAIL to PASS, commit. When `test-wasmtime-misc-
runtime` reaches 0 failures, add it to `test-all` aggregate and
proceed to 6.F. Per ROADMAP §9.6 / 6.J the close is **strict 100%
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
