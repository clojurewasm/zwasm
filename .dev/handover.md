# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state — WASI-0.3 campaign (D-335); ζ2 Slice 3b done — read/write BLOCKED/DROPPED e2e (`90e2bd55`)

**WASI 0.3 / Preview 3 campaign** (Front D, ratified 2026-06-11; CM-async — `async` func / `stream<T>` /
`future<T>`, NOT core stack-switching). Critical path A→B→C→D(crux)→E→F→G; full unit plan + per-unit DONE-SHAs
in debt **D-335**. Loop drives all fronts autonomously; only tag-cut is user-reserved (ADR-0156).

**DONE (per-SHA detail in D-335)**: Units A/B/C — stream/future valtypes (0x66/0x65) + 14 canon builtins
(0x0e–0x1b) + value-ABI as i32 handles · D Zone-1 model α..ζ1+ηA in `async.zig` (handle/stream/future tables,
rendezvous, `EventCode`/`WaitableSet`, `Subtask`, `driveCallbackLoop`, `WaitableSetTable`; ADR-0187 stackless
callback ABI, no fibers) · ηB decode (canonopts `async`/`callback`; `task.return` 0x09) · **P3 runner**
(`component_wasi_p3.zig`, ADR-0188): async export runs end-to-end — `P3CallbackCtx` installs the
`invokeCallback`(→`Instance.invoke`)/`waitOn`(→`WaitableSetTable.poll`, trap `error.AsyncDeadlock`) seams;
EXIT + YIELD→callback-reentry both e2e green · **ζ2 Slice 1** (`48b052ca`, ADR-0189): `canon task.return` host
builtin (`WasiP2Ctx.task_return` + `Def.task_return_builtin` + `p2TaskReturn`) delivers the async result —
fixture calls task.return(42)→EXIT, `ctx.task_return == 42` · **ζ2 Slice 2 Zone-1** (`eb3107a4`, ADR-0189):
`SharedTable` (refcounted arena of `Shared = union{SharedStream, SharedFuture}`) + `StreamFutureEnd.shared`
link + `newStreamPair`/`newFuturePair` (mint a linked readable+writable pair, refcount=2) + `dropEnd` (free
the shared at the 2nd drop). Adversarial drop-order unit tests (fwd/rev/free-list reuse) · **ζ2 Slice 2 Zone-3** (`dc39cad3`, ADR-0189): async tables (streams/shared/sets)
moved into `WasiP2Ctx`; `synthDef .stream_future → Def.async_builtin` for stream.new/future.new; `p2StreamNew`/
`p2FutureNew` trampolines (via `AsyncBuiltinCtx`) wrap `newStreamPair`/`newFuturePair` returning `ri|(wi<<32)`;
e2e `async_stream_new.wat` calls stream.new→EXIT, two ends minted · **ζ2 Slice 3a** (`6592ed1f`, ADR-0189):
`p2StreamFutureDrop` wires the 4 `drop-{readable,writable}` ops — `StreamFutureEnd.drop` marks shared dropped
(traps if copying) + `dropEnd` releases the end/shared ref; `WasiP2Error` widened with `async_mod.Error` so
trampolines `try`-propagate; e2e `async_stream_drop.wat` mints+drops both ends. (Lesson reminders: `zig build
test` ≠ `test-all`; `catch {}` in errdefer + `else` on an exhaustive enum switch are gate/lint-blocked.
`D-337` = deferred writable-future-drop guard.)

**Investigation (`023a07cd`, lesson `2026-06-16-stackless-stream-completion-needs-host-peer` + ADR-0189 Rev)**:
the stackless single-task runner (ADR-0187, no fibers) **cannot reach a guest-to-guest stream/future read/write
COMPLETION** — a blocked op returns to the callback loop with no continuation, so the peer never acts.
COMPLETION + element marshalling + the WAIT-path e2e payoff **gate on Unit E** (a host stream peer) — NOT pure
ζ2. ζ2 Slice 3 re-scoped (ADR-0132 carve-out) to the single-task-testable outcomes.

read/write BLOCKED/DROPPED wired (`90e2bd55`): `p2StreamFutureCopy` (one trampoline; `copy()` dispatches
read/write on the end's side) → `Step`→`ReturnCode`; e2e read-no-writer→BLOCKED + drop-then-read→DROPPED
(guest self-asserts via `unreachable`). COMPLETION(n>0) traps until Unit E supplies the marshalling+peer.

**NEXT — ζ2 Slice 3c: `cancel-read`/`cancel-write` (closes ζ2's single-task scope)**:
- Wire the 4 cancel ops (currently `UnsupportedWasiImport`) → `StreamFutureEnd.cancel(shared)` → `ReturnCode`.
  Single-task testable: a guest `stream.read`s (→ BLOCKED, end parks `async_copying`), then `stream.cancel-read`
  → returns cancelled (state → idle). Bind via the existing `AsyncBuiltinCtx`/`p2*` pattern.
- Fixture: read (BLOCKED) → cancel-read → assert the cancelled code; EXIT.
- **Then ζ2 is single-task-complete** → **Unit E** (WASI-P3 host interfaces: the host stream peer that unlocks
  read/write COMPLETION + element marshalling + the WAIT-path e2e), then F (async public API), G (p3 corpus).

## Active bundle

- **Bundle-ID**: wasi03-D-335 (§9.0 Front D; WASI 0.3 / Preview 3; units A→G)
- **Cycles-remaining**: ~1 (ζ2 Slices 1+2+3a+3b done; remaining = Slice 3c cancel → ζ2 single-task-complete, then Unit E)
- **Continuity-memo**: critical path **A→B→C→D(...Slice3b read/write BLOCKED/DROPPED done; Slice3c=cancel next; COMPLETION→Unit E)→E→F→G**
  (full plan in **D-335**; design in **ADR-0187** — stackless callback ABI, no fibers). CM-async, NOT core
  stack-switching. Spec: `~/Documents/OSS/{WASI, WebAssembly/component-model}` (design/mvp/{Binary,CanonicalABI,
  Concurrency}.md); ref impl `~/Documents/OSS/wasmtime` (43+; `concurrent/futures_and_streams.rs`).
- **Exit-condition**: a WASI-0.3 async/stream/future component runs end-to-end through zwasm (new P3
  corpus green, 3-host); each unit lands green per D-335 along the way.
- **Current unit — D (HIGH/crux; ζ2 Slice 3b done, Slice 3c cancel START HERE)**: P3 runner
  + task.return + stream/future new+drop + read/write(BLOCKED/DROPPED) all e2e green. Remaining = Slice 3c
  (cancel-read/write → closes ζ2's single-task scope) → then **Unit E** unlocks read/write COMPLETION + element
  marshalling + the WAIT-path e2e. Then F/G.

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
