# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state — WASI-0.3 campaign (D-335); Unit E host peers (E1/E3/E2a/E2b) done (`85817b84`)

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

WAIT mechanism (survey): zwasm is STACKLESS so the guest's `callback` RETURNS `WAIT(set)` (not the stackful
`waitable-set.wait` builtin); `unpackCallbackResult` already extracts the set index; `waitable-set.wait`/`poll`
are reject-deferred. The Zone-1 + builtins are all in place; only the e2e wiring remains.

**NEXT — Unit E2c: the WAIT-path e2e** (the last callback-loop gap; today only EXIT/YIELD are e2e):
- A guest reads a host-SOURCE stream that is INITIALLY empty so `stream.read` BLOCKs (parks `async_copying`),
  `waitable-set.new` + `waitable.join(set, readable)`, then returns `WAIT(set)` (its `callback`/entry packs
  `(2 | set<<4)`). The host source then delivers bytes → sets the end's `pending_event` → `driveCallbackLoop`'s
  WAIT branch → `waitOn(set)` → `WaitableSet.poll` returns STREAM_READ → re-enter `callback` → guest re-reads →
  COMPLETED + EXIT.
- **The new bit**: a 2-PHASE host source (initially-empty so the read parks, then a trigger delivers bytes +
  sets the pending event). The runner's `P3CallbackCtx.waitOn` already polls the set table; the trigger is
  what's missing. Survey the cleanest trigger (a host-source "deliver" step the runner calls before `waitOn`,
  or a fixture-driven second guest call). **Likely needs a small ADR** for the 2-phase source + the WAIT-loop
  drive shape (the e2e must exercise the real `driveCallbackLoop` WAIT branch, not a stub).
- Gaps: multi-byte/typed marshalling (E1/E3 did `u8`); return-future resolution. Then F/G. (**D-444** P3-host split.)

## Active bundle

- **Bundle-ID**: wasi03-D-335 (§9.0 Front D; WASI 0.3 / Preview 3; units A→G)
- **Cycles-remaining**: ~3 (D + E1/E3 + E2a/E2b done; remaining = E2c WAIT-path e2e → F → G)
- **Continuity-memo**: critical path **A→B→C→D(DONE)→E(host peers: E1/E3/E2a/E2b done; E2c WAIT-e2e next)→F→G**
  (full plan in **D-335**; design in **ADR-0187** — stackless callback ABI, no fibers). CM-async, NOT core
  stack-switching. Spec: `~/Documents/OSS/{WASI, WebAssembly/component-model}` (design/mvp/{Binary,CanonicalABI,
  Concurrency}.md); ref impl `~/Documents/OSS/wasmtime` (43+; `concurrent/futures_and_streams.rs`).
- **Exit-condition**: a WASI-0.3 async/stream/future component runs end-to-end through zwasm (new P3
  corpus green, 3-host); each unit lands green per D-335 along the way.
- **Unit D + E1/E3/E2a/E2b DONE (HIGH/crux); E2c START HERE**: Zone-1 model + P3 runner + ζ2 + both host stream
  peer directions + waitable-set decode + new/join builtins all green. Next = E2c (the WAIT-path e2e: a 2-phase
  host source → guest blocks → returns WAIT(set) → `driveCallbackLoop` WAIT branch re-enters callback; survey+
  small ADR for the 2-phase source + WAIT-loop drive). Then F/G. (D-444 = P3-host split when E settles.)

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
