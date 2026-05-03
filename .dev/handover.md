# Session handover

> Read this at session start. **Replace** (not append) the `Current state`
> block + the `Active task` table at session end. Keep the whole file
> ≤ 100 lines — anything older than the active task lives in `git log`.
> Authoritative plan is `.dev/ROADMAP.md`; stable file shape lives in
> `CLAUDE.md` "Layout".

## Next 3 files to read (cold-start order)

1. `.dev/handover.md` (this file).
2. `.dev/decisions/0014_redesign_and_refactoring_before_phase7.md` —
   §9.6 / 6.K work-item block (Value funcref, ownership model,
   cross-module imports, element forms 5/7, Label arity, partial-
   init re-measure).
3. `.dev/decisions/0012_first_principles_test_bench_redesign.md` —
   Phase 6 reopen scope.

## Current state

- **Phase**: **Phase 6 IN-PROGRESS, BLOCKED on 6.K.3** pending
  6.K.6-class lifetime fix (see Open questions / blockers).
- **Last source commit**: `6c223a9` — chore(p6) mark §9.6 / 6.K.8
  [x]; delete ADR drafting override; retarget at 6.K.3. Baseline
  242/29 misc-runtime fails restored.
- **6.K.3 work attempted then reverted in this session** — the
  spike unblocked table / global / func cross-module imports at
  the c\_api level (drop the three `Unsupported*Import` guards,
  add a cross-module call thunk in `host_calls`, set imported
  `FuncEntity.runtime = source_rt`, switch `Runtime.globals` to
  `[]*Value` with parallel `globals_storage`). Build green. But
  exposed a pre-existing partial-init lifetime bug
  (see blocker §1). Revert: `git restore src/`. The design notes
  + survey survive at `private/notes/p6-6K3-survey.md`.
- **Branch**: `zwasm-from-scratch`, pushed.

## Active task — §9.6 / 6.K.3 BLOCKED. Next-tractable: §9.6 / 6.K.4 or 6.K.5

Per the autonomous loop's stop conditions, blocker §1 below is a
**bucket-2 stop** (genuinely unsolvable without a load-bearing
trade-off). The user must decide one of:

- **(A) Re-prioritise 6.K.6 (partial-init lifetime fix) before
  6.K.3.** ADR-0014's "files touched" / "acceptance" list for
  6.K.6 likely needs amending to include "imported-instance
  arena keep-alive on instantiation failure" or equivalent.
  After 6.K.6, return to 6.K.3 spike.
- **(B) Land 6.K.3 with a guard against the partial-init scenario**
  (e.g., reject element-segment writes to imported tables when the
  importer might fail mid-init). Trades spec fidelity for
  unblocking the misc-runtime fixtures that don't trigger
  partial-init (table_copy_on_imported_tables, embenchen_*1,
  externref-segment, elem-ref-null, call_indirect.1). ~5 of 19
  failing fixtures still wouldn't pass. Needs ADR amendment.
- **(C) Run 6.K.4 + 6.K.5 first** (parallel-eligible per
  ADR-0014); they don't depend on cross-module dispatch. Returns
  to 6.K.3 once 6.K.6 lands.

The autonomous loop **does not** decide between (A) / (B) / (C)
without explicit user direction.

## ROADMAP §9.6 — task table snapshot (authoritative is `.dev/ROADMAP.md`)

| #     | Description                                                                          | Status         |
|-------|--------------------------------------------------------------------------------------|----------------|
| 6.K.1 | `Value.ref` → `*FuncEntity` pointer encoding                                         | [x] 296d78e    |
| 6.K.2 | Single-allocator Runtime + Instance back-ref; drop `memory_borrowed`                 | [x] e6e5c20    |
| 6.K.3 | Cross-module imports for table / global / func                                       | [ ] **BLOCKED** |
| 6.K.4 | `decodeElement` forms 5 / 6 / 7 (parallel)                                           | [ ]            |
| 6.K.5 | Label arity formalisation + `single_slot_dual_meaning.md` + §14 entry (parallel)     | [ ]            |
| 6.K.6 | Re-measure `partial-init-table-segment/indirect-call` after 6.K.1–6.K.3              | [ ]            |
| 6.K.7 | -Dsanitize=address + zig build run-repro (per ADR-0015)                              | [ ]            |
| 6.K.8 | Error diagnostic M1 (Diagnostic core + CLI parity, per ADR-0016)                     | [x] 306dbc2    |

## Open questions / blockers

### §1 — 6.K.3 partial-init dangling-FuncEntity-pointer

**Root cause**: when an importer's instantiation traps mid-element-
segment processing on an imported table, the partial-init writes
have already stored `*FuncEntity` pointers into the SOURCE
instance's table. Those pointers reference the IMPORTER's
`func_entities` array, allocated on the importer's arena. The
catch in `wasm_instance_new` then destroys the importer's arena
(`freeInstanceState` → `arena.deinit`). Subsequent reads of the
source's table — e.g., `call_indirect` from a module-0 export
that the wast runner invokes — dereference a now-freed
`*FuncEntity` and **segfault** (`mvp.zig:344` on
`callee_rt.funcs.len` at offset 0x50 from a freed `Runtime`).

**Reproduces with the 6.K.3 spike code**: removing the three
`UnsupportedCrossModuleTableImport` / `…GlobalImport` /
`…FuncImport` guards in `c_api/instance.zig` lets the importer
reach element-segment processing. The `partial-init-table-segment`
reftypes fixture intentionally OOBs its second segment; pre-spike
the importer rejected at the guard so module 0's table stayed
clean. Post-spike, partial-init writes a dangling pointer into
module 0's table; the next assert\_return on module 0's
call\_indirect crashes.

**ADR-0014 §2.1 / 6.K.3 didn't anticipate this**. Its acceptance
criterion (1) ("misc-runtime fail count drops to ≤ 1, the
partial-init-table fixture reserved for 6.K.6") was correct that
6.K.6 owns the partial-init re-measure — but 6.K.3 itself
becomes **unrunnable** when the partial-init segfault cascades to
unrelated fixtures. The dangling pointer issue is logically a
6.K.6 concern that 6.K.3 cannot avoid touching.

**Tractable fixes** (ranked by effort):

1. **Keep the importer's arena alive after instantiation failure**
   until `wasm_store_delete` (or until no foreign reference
   remains). Smallest change to wasm.h shape — `wasm_instance_new`
   still returns null on failure, but the partial Instance lives
   on a per-Store "failed instances" list. ~50 LoC.
2. **Detect cross-module elem-seg writes pre-emptively**: before
   any elem-seg write to an imported table, validate ALL segments
   first. If any is OOB, reject the whole instantiation
   atomically (no partial init). Violates Wasm 2.0 spec strictly,
   but matches Wasm 1.0 semantics. A new `# DEFER:`-marked
   fixture in the misc-runtime manifest documents the v2 deviation
   per ROADMAP §9.6 / 6.J.
3. **Allocate FuncEntity in a longer-lived allocator** (e.g.,
   per-Store instead of per-instance). Touches the ownership
   model 6.K.2 just unified; arguably regresses it. Not
   recommended without ADR amendment.

**Recommended path**: option 1 + amend ADR-0014 to make 6.K.6
include the keep-alive logic, then return to 6.K.3. Estimated 1
extra cycle.

## Phase 6 close → Phase 7 (JIT v1 ARM64) — direct transition

ADR-0014 cancels the placeholder "post-Phase-6 refactor phase"
wiring. Phase 7 is unchanged. The `continue` skill's standard
§9.<N> → §9.<N+1> phase boundary handler applies as-is once
6.K + 6.E + 6.F / 6.G / 6.H / 6.I + 6.J all `[x]`.

## Outstanding spec gaps (Phase 6 absorbs)

- multivalue blocks (multi-param) — closes alongside 6.K.5
- element-section forms 2 / 5 / 6 / 7 — closes at 6.K.4
- ref.func declaration-scope — Phase 2 chunk 5e (independent)
- 13 wasmtime_misc BATCH1-3 fixtures queued (validator gaps)
- 39 trap-mid-execution realworld fixtures — through 6.E + 6.K.3
- 10 SKIP-VALIDATOR realworld fixtures
- 29 wasmtime_misc runtime-runner failures (partial fix gated on
  blocker §1 above)
- ADR-0016 M2/M3/M4/M5 — frontend / interp location, C-ABI
  accessors, backtraces (deferred per ADR-0016)
