# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state — WASI-0.3 campaign (D-335); Units A+B+C DONE; branch GREEN (`58e3f46a`)

**WASI 0.3 / Preview 3 campaign is the active feature work** (Front D, ratified 2026-06-11; CM-async —
`async` func / `stream<T>` / `future<T>` — NOT core stack-switching). Critical path A→B→C→D(crux)→E→F→G;
full unit plan + per-unit DONE-SHAs in debt **D-335**. The loop drives ALL fronts autonomously, only
tag-cut is user-reserved (ADR-0156). **Decode + the canon VALUE-ABI are now complete; D is the runtime crux.**

**Done so far**:
- **Unit A** (`95a23c53`+`e5acb989`): `stream<t?>`/`future<t?>` valtypes (0x66/0x65) decode (element is
  **optional** `<valtype>?`, unlike `list`) + validation (payload bounds + reject `(stream char)`/transitive
  `borrow`). Test block extracted to `types_tests.zig` (hard-cap).
- **Unit B** (`0376ee44`): 14 canon `stream.*`/`future.*` builtins (0x0e–0x1b) — `StreamFutureOp` +
  `Canon.stream_future`; each mints a `CoreFuncDef.stream_future`; P2 runner rejects (P3 = Units E/F).
- **Unit C** (`58e3f46a`): stream/future VALUES marshal as **i32 handles, identical to `own`** — `CanonType`
  `.stream`/`.future` + arms in flatten/lower/lift/store/load/liftTyped (grouped with `.own`; valid as results,
  unlike `.borrow`). Pure pass-through; the handle TABLE lifecycle is Unit D. Typed public API defers (Unit F).
- **D-336 part a** (`210f081d`): functype `result` rejects transitive `borrow`; part b blocked-by the
  untracked value index space (sort=value deferred).

**NEXT — Unit D (async task/waitable RUNTIME — the architectural crux, HIGH risk, ~1200 LOC, multi-cycle).**
New `src/feature/component/async.zig`: per-component stream/future handle TABLE + lifecycle (the table
Unit C's i32 handles index into), async task/waitable model, `ReturnCode` packing (wasmtime: Blocked
0xffff_ffff / Completed / Dropped / Cancelled). **Step 0 = mandatory SPIKE first** — deep-read wasmtime
`crates/wasmtime/src/runtime/component/concurrent/futures_and_streams.rs` + `concurrent.rs` + CM
`Concurrency.md`; design an ADR for the table+task model BEFORE redesign code (this is bundle-mode
multi-cycle within Unit D). Verify the prior remote kick at Step 0.7.

## Active bundle

- **Bundle-ID**: wasi03-D-335 (§9.0 Front D; WASI 0.3 / Preview 3; units A→G)
- **Cycles-remaining**: ~5+ (A+B+C done; D = async task/waitable runtime is the multi-cycle crux)
- **Continuity-memo**: critical path **A(done)→B(done)→C(done)→D(crux)→E→F→G** (full plan in **D-335**).
  CM-async, NOT core stack-switching. Spec: `~/Documents/OSS/{WASI, WebAssembly/component-model}`
  (design/mvp/{Binary,CanonicalABI,Concurrency}.md); ref impl `~/Documents/OSS/wasmtime` (43+;
  `concurrent/futures_and_streams.rs` is the handle-table model). Unit C's i32 handles index the Unit-D table.
- **Exit-condition**: a WASI-0.3 async/stream/future component runs end-to-end through zwasm (new P3
  corpus green, 3-host); each unit lands green per D-335 along the way.
- **Current unit — D (START HERE; HIGH/crux)**: async task/waitable runtime + stream/future handle-table
  lifecycle + `ReturnCode` in a new `async.zig` (~1200 LOC). SPIKE wasmtime first + ADR before redesign
  code. Multi-cycle (bundle-within-unit). Done = a stream/future handle round-trips through the table.

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
