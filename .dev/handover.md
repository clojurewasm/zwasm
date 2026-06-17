# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state — Phase 17 完成形 completion-refinement (release = USER-ONLY, ADR-0156)

Project at the **完成形 plateau** (all dims confirmed): clean (C/Zig/CLI audits), full-featured (WASI complete +
now cross-component STRING composition, D-305 milestone), 100% spec (`test-spec` 25539/0), lightweight-yet-fast
(v1-JIT parity, D-265 closed). Robustness: interp+JIT fuzz 0 crashes. Closed-arc detail lives in git/ADRs/lessons.

**D-305 cross-component linker — COMMON shapes ALL DONE + 3-host/x86_64-verified** (ADR-0196; detail in the
D-305 debt row + git): string/list params (@689040e6), string result (@184b5e05), `(string)->string` (@2b9b14ee),
boundary error-trap (@30bd1881, SECURITY — marshalling failures now TRAP, not silent-wrong). component_model
163/0; ubuntu OK @dfdcfdcf. Remaining rare shapes (record/result aggregates, >2-param arities) = consumer-gated
debt, do NOT grind speculatively.

**Prior arcs**: wasi:random COMPLETE; ADR-0193 feature-separation + version SSOT; D-335 typed marshalling DONE;
C-API @b4d75506 (Windows export fix); interp+JIT fuzz 808 mods 0 crashes. ADR-0193 (D-462) + D-461 (ADR-0194)
CLOSED (below). **windowsmini RESUMED**. Version `2.0.0-alpha.3`. Windows batch verifies @…+@2b9b14ee next fire.

## Active bundle — ADR-0195 multi-task async scheduler (UNBLOCKED 2026-06-17 PM)

- **Bundle-ID**: adr0195-scheduler-IIa..b (guest↔guest async = D-335 last functional gap)
- **Cycles-remaining**: ~1-2 (✓II(a)→✓b→✓c-1→✓c-2a→✓c-2b routing→✓d-a→✓d-b-1→✓d-b-2 future→✓d-c-1 sync stream →
  (d-c-2 BLOCKING + pollSet) → (e) adversarial)
- **Continuity-memo**: SYNCHRONOUS cross-component async fully works — routing, task.return, result round-trip,
  future rendezvous, multi-element stream rendezvous (B writes during the entry invoke, A reads after). The ONLY
  remaining functional gap = the BLOCKING case: A reads/waits BEFORE B writes → needs `GraphAsyncCtx.pollSet`
  (today null) to deliver the peer's `pending_event` so the scheduler re-enters the parked task.
- **II(a) DONE** (@529cfcba) + **(b) DONE** (@b90cbecb TaskTable, @61c4a20d driver refactor): `driveCallbackLoop`
  now drives a `TaskDescriptor` via the `stepTask` primitive (seed→loop stepTask until done), byte-identical
  (char net + component corpus 163/0 green, ubuntu+win verified through @8352ef9c). Zone-1 `TaskTable`/
  `TaskDescriptor`/`TaskState{ready,waiting,done}` exist + lifecycle-tested; `stepTask`/`seedTask` are the
  per-step primitive step (c) reuses over `TaskTable` slots.
- **✓ DONE so far** (detail in git/commits): **II(a)** char net @529cfcba · **(b)** `TaskTable`/`TaskDescriptor`/
  `seedTask`/`foldResult` @b90cbecb+@61c4a20d · **(c-1)** Zone-1 `driveScheduler` (round-robin + non-blocking
  `pollSet` + all-waiting→`AsyncDeadlock`; seam `invokeTaskCallback(funcidx)`+`pollSet`) @822d30d5 · **(c-2a)** P3
  runner unified on `driveScheduler`(1-entry table), retired `driveCallbackLoop`/`stepTask` @54a9b0bc+@c7710cda ·
  **(c-2b core)** cross-component async ROUTING works @a0e2d4c7a — `ComponentGraph.driveAsyncMain` owns ONE
  `TaskTable`; `GraphAsync.callbacks` registry routes `invokeTaskCallback(funcidx)`→(instance, callback);
  `installAsyncBoundary`(forks on `ResolvedLift.is_async`) mints a `Subtask`+enqueues a `TaskDescriptor`.
- **(d-a) DONE** (@cc63edd9 + @e7a3d8d9): cross-component async `task.return(42)` captured graph-side into a
  per-task `TaskDescriptor.result: ?u32` (no collision); `GraphAsync.current_task_id` set before each callee
  invoke; graph-wired `graphTaskReturn` host func + `taskResult(id)` accessor. Fixture asserts B's task 2 == 42.
- **(d-b-1) DONE** (@7cf62e3a, inline TDD red→green, full gate verified): **A now CONSUMES B's result**.
  `enqueueCalleeSubtask` returns the task id; `asyncBoundaryRetTrampoline` reads B's synchronously-resolved
  `.result` + writes it (flat-4 i32) into the IMPORTER's memory at `retptr` (`bctx.importer` threaded through
  `installAsyncBoundary`). Fixture `two_async_components_consume_result.wat` (A reads mem[0]→42, task.returns it);
  test asserts A's own task 1 == 42. A blocked-callee (no result yet) stays unwritten = async-completion path (later).
- **(d-b-2) DONE** (@4a344503) + **(d-c-1) DONE** (@9eabb709): SYNCHRONOUS (write-before-read) guest↔guest
  **future** + multi-element **stream** rendezvous. `GraphAsync` owns ONE graph-level `SharedTable`+`StreamFutureTable`;
  `graphFuture*`/`graphStream*` builtins (wired via `pourSyntheticExport` `.stream_future` arm) mint/look-up there so
  a handle minted in A is valid in B (only the i32 crosses). Value channel: `SharedFuture.value[8]` + `SharedStream.buf[64]`
  (count-only rendezvous; writer deposits from `caller.memory()`, reader drains). Async boundary takes ONE flat-i32
  handle param. Fixtures assert A's task 1 == 42 (mutation-proven). **D-463** = shared-table isolation simplification.
  Deferrals (loud): cancel ops, param+retptr, >cap.
- **(d-c-2) DONE** — BLOCKING guest↔guest stream rendezvous + pollSet/waitable-set delivery. B (callee)
  `stream.read`s → BLOCKED → `waitable-set.new`+`join`+WAIT → B's task GENUINELY `.waiting`; A writes later →
  `graphStreamWrite`'s `step.notify` copies bytes into B's recorded reader-memory (`GraphAsync.pending_graph_reads`,
  keyed by read-end handle) + `end.copy` sets B's read-end `pending_event`; `GraphAsyncCtx.pollSet` (now polls
  `GraphAsync.sets` member `pending_event`) harvests it → scheduler re-enters B → B reads {20,22}→sums→task.return(42).
  Graph waitable-set builtins (`graphWaitableSetNew`/`graphWaitableJoin`, mirror p2) wired via the new
  `pourSyntheticExport` `.waitable_set` arm (wait/poll/drop = loud UnsupportedBoundaryType). Fixtures:
  `two_async_components_stream_blocking.wat` (B's task 2 == 42) + `two_async_components_stream_deadlock.wat` (A never
  writes → `error.AsyncDeadlock`, the (e)-adjacent guard). 2941/2953 unit + comp-spec 163/0 + lint/fallback/zone green.
- **Exit-condition**: `async_two_tasks_stream_rendezvous.wat` (2-component: A async-imports B's async export)
  builds + asserts Subtask creation→resolution + waitable-set delivery, e2e green; full async corpus + (e)
  adversarial (deadlock/dropped/cancelled) green; single-task path unchanged.

## Recently closed arcs (detail in ADRs/git/debt — one-liners)

- **D-305 first milestone** (@4cceeb1e, ADR-0196): cross-component STRING marshalling; `component_graph.zig`
  two-level instantiation + boundary trampoline via `canon.CanonContext`. Common shapes now ALL done (see top).
- **D-461 regalloc-origin rework** (ADR-0194, @3cd2ede6, CLOSED Phase I-V): x86_64 v128-spill OOB fixed by
  threading per-arch `max_reg_slots_gpr` into `computeSpillOffsets`; arm64 2922 + x86_64-Rosetta green. Result-write
  remainder (Extend/Extadd/replace_lane/binop-dsts, x86_64, EXOTIC) = D-461 debt row.

## Closed/paused (detail in git + debt.yaml)

- **doc-inventory freshening DONE** (`42441634` README + ADR-0193 P4 doc-sync): reader-facing surfaces clean
  (C-API 293/293, component 158/0/0, Wasm 2.0 skip-impl==0, 3.0 all-9-proposals, version anchors retired).
- **ADR-0192 wasmtime differential campaign — paused**: goal met (9 real engine bugs fixed via wasmtime
  misc_testsuite + 6 SIMD via D-457). Residuals: **`D-460`** v128-GC (arm64 struct/array get/set EMIT DONE
  `f79a3ced`/`41015a9b`; array.new_fixed/copy + x86_64 mirror unblocked NOW by the D-461 spill fixes in progress),
  **`D-209`** memory64 >4 GiB offset, **D-456** host-import fixtures (parked). Harness `scripts/wasmtime_misc_*.sh`.

**Closed campaigns (detail in git/lessons)**: prior 4-front async-maturity (2026-06-16) — ② wasmtime async .wast
TIER-1 (`afcf889a`/`05b35c28`; D-446/447 deferred), ① wasip3 conformance (7 real-rust fixtures, `.#gen-wasip3`),
④ perf (ROI-rejected single-pass ceiling, D-450), ③ real-world GC corpus (6 engine bugs FIXED: D-451-453/9064faa5/
480809af/9ec68a75/79742cb4; 4 GC edge fixtures; real Hoot execution → D-454). **WASI 0.3/Preview-3 core DONE**
(D-335; ADR-0187-0191). validator.zig at 3449/3450 cap — NEXT validator edit MUST extract per the file's marker plan.

## Long-tail (debt-tracked / parked — NOT active; see debt.yaml)

- **JIT-correctness** (front B / parked): D-330 c_sha256 `\n` (parked — conflicting-constraint; do NOT re-run the
  blanket fix) · D-331(A) go runtime-corruption (infra-blocked) · D-331(B)/D-289 go_regex emit (parked) · D-333
  (br_table, folds into D-330). Realworld corpus interp-green; JIT run-stage opt-in (`ZWASM_JIT_RUN=1`). Trace:
  `ZWASM_DEBUG=jit.dump` + `scripts/jit_value_trace.sh` (Recipe 18).
- **D-454** (future-bucket): real GC-language program execution fixture, blocked on Hoot reflect-ABI host port.

## State (all 3-host green @046d9c67/win @886d0667; release = USER-ONLY, ADR-0156)

- **Wasm 1.0/2.0/3.0**: 100% spec, 0 skip (GC 362/0). **WASI 0.1** complete; **0.2/CM** default-ON (corpus 158/0/0);
  **0.3 core** done. Sandboxing triad everywhere.
- **Surfaces**: C-API 293/293 · Zig-API complete (full WASI parity) · lean CLI · memory-safety sound · dogfooded into
  cw. Runners ReleaseSafe (ADR-0177; `check_releasesafe_runners.sh`).
- **EH**: cross-instance JIT EH on BOTH arches (arm64 `4f73d9ee` + x86_64 `c534afca`). Interp + JIT EH corpus green.
- **Debt**: 61 entries; `now`-class = D-462 (feature-separation, ADR-0193, user-gated), D-460 (v128-GC partial),
  D-461 (SIMD-spill, blocks D-460). D-335 (WASI 0.3 core) DONE. Rest front-tagged (future-bucket/parked).
- **Realworld corpus**: 56 fixtures (c/cpp/emcc/go/tinygo/rust/zig), interp 56/0; JIT run-stage opt-in.
- **Tag**: `v2.0.0-alpha.3` tag-only (no Release → Latest stays v1.11.0), USER-ONLY.

## Key refs

- [`flake.nix`](../flake.nix) `devShells.gen` / `.#gen-wasip3` — fixture toolchains. [`docs/zig_api_design.md`](../docs/zig_api_design.md).
- ADRs: **0156** (NO autonomous release) · **0153** (rework) · **0187-0191** (CM-async) · **0185** (x86_64 EH) ·
  **0099** (file-size caps) · **0126** (iso-recursive canonical equality).
- lessons INDEX: `.dev/lessons/INDEX.md` (keyword index for Step 0.4).
