# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state — WASI-0.3 campaign (D-335); D done (ζ2 single-task) + ADR-0190 Unit-E plan (`4c528925`)

**WASI 0.3 / Preview 3 campaign** (Front D, ratified 2026-06-11; CM-async — `async` func / `stream<T>` /
`future<T>`, NOT core stack-switching). Critical path A→B→C→D(crux)→E→F→G; full unit plan + per-unit DONE-SHAs
in debt **D-335**. Loop drives all fronts autonomously; only tag-cut is user-reserved (ADR-0156).

**DONE (per-SHA detail in D-335)**: Units A/B/C (stream/future valtypes + 14 canon builtins + value-ABI) · D —
Zone-1 async model in `async.zig` (handle/stream/future tables, rendezvous, `EventCode`/`WaitableSet`/
`WaitableSetTable`, `Subtask`, `driveCallbackLoop`, `SharedTable` refcount arena; ADR-0187 stackless, no fibers)
+ ηB decode (canonopts, `task.return`) + **P3 runner** (`component_wasi_p3.zig`, ADR-0188: async export runs
e2e via the callback loop; `P3CallbackCtx` installs `invokeCallback`/`waitOn`; EXIT+YIELD e2e) + **ζ2
canon-async-builtin dispatch — COMPLETE single-task** (ADR-0189): async state in `WasiP2Ctx`, `synthDef →
Def.{task_return_builtin, async_builtin}`, ALL builtins host-wired — `task.return` (delivers result),
`stream.new`/`future.new` (`ri|(wi<<32)`), `drop-{r,w}`, `read`/`write` (BLOCKED/DROPPED), `cancel-{r,w}`;
**8 async e2e fixtures green**. (Lessons: `zig build test`≠`test-all`; `catch {}` in errdefer + `else` on an
exhaustive switch are gate/lint-blocked; **stackless single-task CANNOT reach a guest-to-guest read/write
COMPLETION** — needs a host peer, lesson `2026-06-16-stackless-stream-completion-needs-host-peer`; COMPLETION +
element marshalling (the `error.OutOfBounds` trap in `p2StreamFutureCopy`) + the WAIT-path e2e are deferred to
Unit E per ADR-0189 Rev (ADR-0132 carve-out). `D-337` = deferred writable-future-drop guard.)

cancel-read/write wired (`e6cfb865`): `p2StreamFutureCancel` → `StreamFutureEnd.cancel` → `ReturnCode.cancelled`;
e2e read(BLOCKED→parks)→cancel-read→CANCELLED. **All `.stream_future` ops now host-wired; ζ2 is single-task-
complete.** 7 async e2e fixtures green (`async_{exit_immediate,yield_then_exit,task_return,stream_new,stream_drop,
stream_read_blocked,stream_read_dropped,stream_cancel}`).

**Unit E plan settled — ADR-0190** (`4c528925`): the host implements a stream's other end (synchronous, no
scheduler/fibers); first interface = **`wasi:cli/stdout.write-via-stream`** (host-as-reader, `u8`, simplest).

**NEXT — Unit E Slice E1: the host stream peer + first COMPLETION e2e** (per ADR-0190):
- A new P3 host interface `wasi:cli/stdout.write-via-stream(stream<u8>)`: classify via `adapter.classifyImport`
  → a new `P2Op`/host-op; the trampoline registers the host as a pending READER on the stream's `SharedStream`
  (`shared.read`), recording the host end.
- Guest `stream.write(writable, ptr, n)` → `p2StreamFutureCopy` COMPLETION branch (currently the
  `error.OutOfBounds` trap): rendezvous with the host's pending read → COMPLETED(n) → **wire `canon.load`** (
  `canon.zig` store/load; inputs `CanonContext`=mem+alloc, `Value`, `CanonType`, `ptr`; `mem_instance` for mem)
  to move the `n` `u8`s from guest mem → host buffer → write fd 1. Guest `drop-writable` → host flush.
- **Fixture**: a guest that `stream.new`s, passes the readable to `write-via-stream`, `stream.write`s "hi\n",
  drops → assert host captured "hi\n" (capture buffer like the existing P2 stdout tests). This is the FIRST
  read/write COMPLETION + element-marshalling e2e. Then E2 (WAIT-path variant), E3 (stdin), then F/G.

## Active bundle

- **Bundle-ID**: wasi03-D-335 (§9.0 Front D; WASI 0.3 / Preview 3; units A→G)
- **Cycles-remaining**: ~3 (D incl. ζ2 single-task-complete; remaining = Unit E host interfaces → F → G)
- **Continuity-memo**: critical path **A→B→C→D(DONE incl. ζ2 single-task-complete)→E(WASI-P3 host interfaces; unlocks read/write COMPLETION)→F→G**
  (full plan in **D-335**; design in **ADR-0187** — stackless callback ABI, no fibers). CM-async, NOT core
  stack-switching. Spec: `~/Documents/OSS/{WASI, WebAssembly/component-model}` (design/mvp/{Binary,CanonicalABI,
  Concurrency}.md); ref impl `~/Documents/OSS/wasmtime` (43+; `concurrent/futures_and_streams.rs`).
- **Exit-condition**: a WASI-0.3 async/stream/future component runs end-to-end through zwasm (new P3
  corpus green, 3-host); each unit lands green per D-335 along the way.
- **Unit D DONE (HIGH/crux); Unit E Slice E1 START HERE**: Zone-1 model + P3 runner + ζ2 all e2e green;
  ADR-0190 settles the host-stream-peer design. E1 = `wasi:cli/stdout.write-via-stream` host-as-reader +
  `p2StreamFutureCopy` COMPLETION marshalling (`canon.load` u8→fd1) → first guest stream.write COMPLETION e2e.
  Then E2 (WAIT-path), E3 (stdin), then F/G.

## Long-tail (debt-tracked / parked — NOT active; see §9.0 fronts + debt.yaml)

- **JIT-correctness** (front B / parked): D-330 c_sha256 `\n` (parked — conflicting-constraint, blanket fix
  thrashes; full findings in D-330 Round 5 + `private/notes/{c_sha256_trace,d330-emit-align-design}.md`; do
  NOT re-run the blanket fix) · D-331(A) go runtime-corruption (infra-blocked) · D-331(B)/D-289 go_regex emit
  (parked) · D-333 (br_table, folds into D-330's deeper fix). Realworld corpus 50/50 interp; JIT run-stage
  opt-in (`ZWASM_JIT_RUN=1`). Trace: `ZWASM_DEBUG=jit.dump` + `scripts/jit_value_trace.sh` (Recipe 18).
- Prior agenda (2026-06-14 realworld-reproduction) folded into front B: Phase A infra DONE, Phase B JIT
  bug-hunt = the JIT-correctness debt above; plan in [`realworld_reproduction_plan.md`](realworld_reproduction_plan.md).

## State (all 3-host green; release = USER-ONLY, ADR-0156)

- **Wasm 1.0/2.0/3.0**: 100% spec, 0 skip. **WASI 0.1** complete; **0.2/CM**
  default-ON (ADR-0182/0183; corpus 158/0/0). Sandboxing triad everywhere.
- **Surfaces**: C-API 293/293 (+preopen_dir/inherit_env, ADR-0184) · Zig-API
  complete (+`WasiConfig.{envs,preopens,io}` — full WASI parity) · lean CLI ·
  memory-safety sound · dogfooded into cw (consumer-side). Runners ReleaseSafe (ADR-0177,
  Rev 2026-06-14 floored `core_comp` too; `check_releasesafe_runners.sh` guards it).
- **EH**: cross-instance exception-handling on JIT works on BOTH arches (arm64 `4f73d9ee`
  + x86_64 D-238/ADR-0185 `c534afca`). Interp + JIT EH spec corpus green.
- **Debt**: 49 entries, **one `now`** (D-335 = WASI 0.3 Front-D campaign / Active bundle); D-336 part-a done →
  now blocked-by (value index space). Rest front-tagged (A/B/C/D-wasi03/future-bucket/parked). D-330/D-331 parked.
- **Realworld corpus**: 50 fixtures (c/cpp/rust/tinygo/go), interp 50/50; JIT run-stage
  opt-in (`ZWASM_JIT_RUN=1`) — the Phase-B signal source. cljw fixtures retired.
- **Tag**: `v2.0.0-alpha.3` tag-only (no Release → Latest stays v1.11.0), USER-ONLY.

## Key refs

- [`realworld_reproduction_plan.md`](realworld_reproduction_plan.md) — the ACTIVE
  AGENDA's full plan. [`flake.nix`](../flake.nix) `devShells.gen` — fixture toolchains.
- [`docs/zig_api_design.md`](../docs/zig_api_design.md) · **ADR-0185** (x86_64 EH
  frame-walk) · **0177** (ReleaseSafe runners) · **0156** (NO autonomous release) ·
  **0153** (rework) · **0109** (Linker/facade API).
- lessons [`releasesafe-runner-floor-audit`] · [`global-predicate-cannot-replace-local-codemap`].
