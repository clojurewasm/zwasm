# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state — WASI-0.3 campaign (D-335); Unit E1 done — host stream peer + first COMPLETION e2e (`612cd1e8`)

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

**Unit E1 DONE** (`612cd1e8`, ADR-0190): the first WASI-0.3 host stream peer. `wasi:cli/stdout`/`stderr`
`write-via-stream` classify to new `P2Op`s; `p2WriteViaStream` registers a host sink (`WasiP2Ctx.host_sinks`:
`SharedStream` handle → P1 fd) + returns a future handle. `p2StreamFutureCopy`'s COMPLETION branch (was the
`error.OutOfBounds` trap) — for a host-sink writable end — marshals the `n` `u8`s from guest mem `ptr` via
`wasi_fd.writeSlice` to the fd → COMPLETED(n). E2E `async_stdout_write_via_stream.wat`: guest writes "hi\n"
through a stream → host captures it. **First guest stream.write COMPLETION + element marshalling.** (p2 crossed
2000 lines → FILE-SIZE-EXEMPT marker; **D-444** = split the P3 async host to a sibling `component_wasi_p3_host.zig`.)

**NEXT — Unit E2/E3** (extend the host-peer surface):
- **E2 — the WAIT-path e2e** (today only EXIT/YIELD are e2e through the runner): a guest that BLOCKs on a
  stream op then a host-peer completion delivers an event + re-enters `callback` via `driveCallbackLoop`'s WAIT
  branch (`waitOn`). May need `waitable-set.new`/`.join` builtins + the future's resolution (the write-via-
  stream return future, deferred in E1). Survey the WAIT seam wiring.
- **E3 — `wasi:cli/stdin.read-via-stream`** (host-as-writer: host supplies bytes, guest reads → COMPLETION the
  other direction) + multi-byte/typed element marshalling (E1 only did `u8`).
- Then F (async-export public API), G (p3 corpus). Per D-335. (Also: **D-444** P3-host file split when E settles.)

## Active bundle

- **Bundle-ID**: wasi03-D-335 (§9.0 Front D; WASI 0.3 / Preview 3; units A→G)
- **Cycles-remaining**: ~3 (D done + Unit E1 host-peer done; remaining = E2 WAIT-path / E3 stdin → F → G)
- **Continuity-memo**: critical path **A→B→C→D(DONE incl. ζ2 single-task-complete)→E(WASI-P3 host interfaces; unlocks read/write COMPLETION)→F→G**
  (full plan in **D-335**; design in **ADR-0187** — stackless callback ABI, no fibers). CM-async, NOT core
  stack-switching. Spec: `~/Documents/OSS/{WASI, WebAssembly/component-model}` (design/mvp/{Binary,CanonicalABI,
  Concurrency}.md); ref impl `~/Documents/OSS/wasmtime` (43+; `concurrent/futures_and_streams.rs`).
- **Exit-condition**: a WASI-0.3 async/stream/future component runs end-to-end through zwasm (new P3
  corpus green, 3-host); each unit lands green per D-335 along the way.
- **Unit D + E1 DONE (HIGH/crux); Unit E2/E3 START HERE**: Zone-1 model + P3 runner + ζ2 + the first host
  stream peer (stdout write-via-stream, COMPLETION + u8 marshalling) all e2e green. Next = E2 (WAIT-path e2e
  through `driveCallbackLoop`'s WAIT branch) / E3 (stdin read-via-stream, host-as-writer + multi-byte
  marshalling). Then F/G. (D-444 = split the P3 async host to a sibling when E settles.)

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
