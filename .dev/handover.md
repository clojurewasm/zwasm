# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state — WASI-0.3 campaign (D-335); callback loop + stream peer contract COMPLETE (`13c7afce`)

**WASI 0.3 / Preview 3 campaign** (Front D, ratified 2026-06-11; CM-async — `async` func / `stream<T>` /
`future<T>`, NOT core stack-switching). Critical path A→B→C→D(crux)→E→F→G; full unit plan + per-unit DONE-SHAs
in debt **D-335**. Loop drives all fronts autonomously; only tag-cut is user-reserved (ADR-0156).

**DONE (per-SHA detail in D-335)**: Units A/B/C (stream/future valtypes + 14 canon builtins + value-ABI) · D —
Zone-1 async model (`async.zig`: handle/stream/future tables, rendezvous, `WaitableSet`/`WaitableSetTable`,
`Subtask`, `driveCallbackLoop`, `SharedTable` refcount arena; ADR-0187 stackless, no fibers) + ηB decode + the
**P3 runner** (ADR-0188: async export runs e2e via the callback loop; EXIT+YIELD e2e) + **ζ2 single-task
COMPLETE** (ADR-0189): all canon async builtins host-wired (task.return, stream/future new/drop/read/write/
cancel; read/write reach BLOCKED/DROPPED — guest-to-guest COMPLETION needs a host peer per ADR-0189 Rev) +
**Unit E host stream peers** (ADR-0190): **E1** stdout/stderr `write-via-stream` (host sink, `WasiP2Ctx
.host_sinks`, guest write→COMPLETION+u8 marshal to fd) `612cd1e8`/`198e210b`; **E3** stdin `read-via-stream`
(host source, retptr tuple, guest read→COMPLETION from stdin) `63fee3d4` — **both stream directions COMPLETE
e2e**; **E2a** waitable-set decode 0x1f–0x23 `116287c1`; **E2b** `waitable-set.new`/`waitable.join` host
builtins `85817b84` (mint a set + join a waitable). **13 async e2e fixtures green.** (Lessons: `zig build
test`≠`test-all`; `catch {}` in errdefer + `else` on exhaustive switch are gate/lint-blocked; stackless
single-task can't reach guest-to-guest COMPLETION — `2026-06-16-stackless-stream-completion-needs-host-peer`.
`D-337` writable-future-drop guard; `D-444` split p2 async host to a sibling.)

**E2c DONE** (`249e8e85`, ADR-0191): the WAIT-path e2e. `WasiP2Ctx.pending_reads` ({ptr,cap} keyed by end) +
`defer_host_source_reads`; `p2StreamFutureCopy` parks a deferred host-source read (record + BLOCKED);
`WasiP2Ctx.deliverParkedReads` copies the ready bytes + `setPendingEvent(STREAM_READ)` for each set member at
`waitOn`; `P3CallbackCtx` holds the `WasiP2Ctx`, `waitOn` delivers-then-polls. E2E `async_wait_path.wat`: guest
read PARKS → returns `WAIT(set)` → host delivers "ok" → `driveCallbackLoop` WAIT branch re-enters callback →
EXIT. **The callback loop is now COMPLETE e2e (EXIT + YIELD + WAIT); both stream directions COMPLETE.**

**Return-future resolution DONE** (`13c7afce`): `WasiP2Ctx.host_result_futures` (the returned future readable
handle); a guest `future.read` on it COMPLETES with the `ok` discriminant (0, 1 byte) — a host peer always
succeeds, no rendezvous/typed-marshalling. E2E `async_future_result.wat`: write "hi" → future.read →
COMPLETED(1)+ok. **The write/read-via-stream interface contract (stream + return future) is now complete.**

**NEXT — Unit E breadth / F / G** (the core async mechanism + the stdio stream contract are proven; remaining
is breadth + the public surface):
- **Typed/multi-byte element marshalling** — E1/E3/E2c moved `u8` only (count==bytes). Generalise the stream
  read/write byte math + the marshalling to arbitrary element WIT types via the Unit-C `canon.zig` store/load
  (resolve the element type from the stream `type_index`, `bytes = count * elem_size`). Needs a typed (non-u8)
  stream interface or a guest-to-guest path to exercise it — scope a fixture first. (Latent: the current code
  treats `count` as bytes — correct only for `u8` streams.)
- **General guest-to-guest stream COMPLETION** — the Zone-1 rendezvous doesn't buffer the in-flight bytes; a
  true guest↔guest copy needs the host to hold both ends' buffers. Separate harder design (likely an ADR).
- Then **F** (async-export public API — the C/Zig embedder surface to drive an async component + read its
  result) and **G** (a `test/component/p3` corpus consolidating the ~15 async fixtures). Per D-335.
  (**D-444** P3-host file split when E settles.)
- Then **F** (async-export public API surface — the embedder C/Zig API for driving an async component) and **G**
  (a `test/component/p3` corpus consolidating the async fixtures). Per D-335. (**D-444** P3-host file split.)

## Active bundle

- **Bundle-ID**: wasi03-D-335 (§9.0 Front D; WASI 0.3 / Preview 3; units A→G)
- **Cycles-remaining**: ~3 (D + E callback-loop + stdio stream contract COMPLETE; remaining = E breadth (typed marshalling) → F → G)
- **Continuity-memo**: critical path **A→B→C→D(DONE)→E(callback loop EXIT/YIELD/WAIT + both stream dirs e2e DONE; breadth next)→F→G**
  (full plan in **D-335**; design in **ADR-0187** — stackless callback ABI, no fibers). CM-async, NOT core
  stack-switching. Spec: `~/Documents/OSS/{WASI, WebAssembly/component-model}` (design/mvp/{Binary,CanonicalABI,
  Concurrency}.md); ref impl `~/Documents/OSS/wasmtime` (43+; `concurrent/futures_and_streams.rs`).
- **Exit-condition**: a WASI-0.3 async/stream/future component runs end-to-end through zwasm (new P3
  corpus green, 3-host); each unit lands green per D-335 along the way.
- **Unit D + E callback-loop + stdio stream contract COMPLETE (HIGH/crux); E breadth START HERE**: Zone-1 model
  + P3 runner + ζ2 + host stream peers (both directions COMPLETE) + waitable-set + WAIT-path + return-future
  all e2e green. Next = E breadth: typed/multi-byte element marshalling (needs a non-u8 fixture) → then F
  (async public API) / G (p3 corpus). (D-444 = P3-host split when E settles.)

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
