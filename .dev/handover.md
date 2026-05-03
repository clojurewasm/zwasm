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

- **Phase**: **Phase 6 IN-PROGRESS** — 6.K.3 unblocked by the
  ADR-0014 amendment landing this session. Implementation cycle
  resumes at the next /continue wakeup.
- **Last source commit**: `6c223a9` — chore(p6) mark §9.6 / 6.K.8
  [x]; delete ADR drafting override; retarget at 6.K.3. Baseline
  242/29 misc-runtime fails. Plus a pending docs commit landing
  the ADR-0014 amendment described below.
- **6.K.3 design redone** (2026-05-04). The earlier spike found
  that the 6.K.1 `*FuncEntity` encoding produces dangling pointers
  on partial-init failures (Wasm 2.0 mandates that prior elem-
  segment writes persist when a later segment OOB-traps; the
  importer's arena destruction then leaves dangling references).
  Research subagent confirmed wasmtime + wazero both solve this
  with **zombie-instance keep-alive at Store level** (Alpha).
  ADR-0014 amended in place: 6.K.2 gains sub-change 4 (Store
  zombie list, parkAsZombie helper, walk in wasm_store_delete);
  6.K.3 gains a runner-layer retention contract for
  `wast_runtime_runner.zig`'s handleInstantiateExpectFail.
  partial-init-table-segment is no longer deferred to 6.K.6 —
  the contract makes it pass end-to-end. Spike code reverted;
  design notes at `private/notes/p6-6K3-survey.md` +
  `private/notes/p6-6K3-lifetime-survey.md`; encoding experiments
  (Beta sketch — rejected) at
  `private/dbg/p6-6K3-lifetime/encoding_experiments.zig` (11/11
  unit tests; gitignored).
- **Branch**: `zwasm-from-scratch`, pushed.

## Active task — §9.6 / 6.K.3 (cross-module imports) — re-attempt with zombie-instance contract

Per the ADR-0014 amendment, 6.K.3 is now a single coherent piece
of work covering:

1. **6.K.2 sub-change 4** (Store zombie list): add
   `Store.zombies: ArrayList(Zombie)` where `Zombie = { runtime,
   arena }`; `parkAsZombie(store, runtime, arena)` helper; the
   catch in `wasm_instance_new` parks instead of destroys; same
   for `wasm_instance_delete`; `wasm_store_delete` walks zombies
   and frees them. Convert `Store` from `extern struct` to plain
   struct (no C-ABI impact since `wasm_store_t` is opaque from
   C's POV). ~50 LoC.
2. **6.K.3 c_api wiring**: drop the three
   `error.UnsupportedCrossModule*Import` guards; the cross-module
   call thunk in `host_calls`; per-slot pointer aliasing for
   globals (`Runtime.globals: []*Value` + `globals_storage`);
   `FuncEntity.runtime = source_rt` for imported funcs.
   ~150 LoC (the spike sketched this; available in the reverted
   diff via `git reflog show stash` if needed; otherwise re-derive).
3. **6.K.3 runner retention**: modify
   `test/runners/wast_runtime_runner.zig`'s
   `handleInstantiateExpectFail` to retain the failed
   ActiveModule in `ctx.all` instead of letting
   `instantiateWithImports`'s errdefers destroy it.
   `buildImports` raises `error.UnregisteredImportSource` (or
   similar) instead of silently null-slotting. ~50 LoC.

Acceptance per the amended ADR:

- `test-wasmtime-misc-runtime` failure count drops to ≤ 1
  (partial-init-table-segment is now in scope, not deferred).
- New unit test "zombie instance: failed instantiation's runtime
  + arena live until store_delete" (per 6.K.2 sub-change 4).
- New unit test for `buildImports` named-error path.

Implementation order (TDD): runner test for zombie-keep-alive
first (red), c_api zombie list (green), drop import guards,
add cross-module wiring + runner retention, run misc-runtime,
re-baseline.

Step 0 Survey is **not needed** this cycle — the prior survey
notes + research subagent output cover the design space; the
remaining work is mechanical implementation per the amended ADR.

## ROADMAP §9.6 — task table snapshot (authoritative is `.dev/ROADMAP.md`)

| #     | Description                                                                          | Status         |
|-------|--------------------------------------------------------------------------------------|----------------|
| 6.K.1 | `Value.ref` → `*FuncEntity` pointer encoding                                         | [x] 296d78e    |
| 6.K.2 | Single-allocator Runtime + Instance back-ref; drop `memory_borrowed`                 | [x] e6e5c20    |
| 6.K.3 | Cross-module imports for table / global / func + zombie-instance contract (per amended ADR-0014) | [ ] **NEXT** |
| 6.K.4 | `decodeElement` forms 5 / 6 / 7 (parallel)                                           | [ ]            |
| 6.K.5 | Label arity formalisation + `single_slot_dual_meaning.md` + §14 entry (parallel)     | [ ]            |
| 6.K.6 | Re-measure `partial-init-table-segment/indirect-call` after 6.K.1–6.K.3              | [ ]            |
| 6.K.7 | -Dsanitize=address + zig build run-repro (per ADR-0015)                              | [ ]            |
| 6.K.8 | Error diagnostic M1 (Diagnostic core + CLI parity, per ADR-0016)                     | [x] 306dbc2    |

## Open questions / blockers

(none — 6.K.3 design is locked via the 2026-05-04 ADR-0014
amendment; implementation cycle resumes with the zombie-instance
contract as a co-deliverable. See `private/notes/p6-6K3-lifetime-survey.md`
§4 for the wasmtime / wazero / spec-interpreter cross-reference
that informed the redesign.)

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
