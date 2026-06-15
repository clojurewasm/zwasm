# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state — Phase 17 completion-refinement; 4-front async-maturity campaign (user-steered 2026-06-16)

**WASI 0.3 / Preview 3 core DONE** (D-335, per-SHA detail in the debt row). The CM-async runtime runs an async
component from `zwasm run` + the embedder (`component.runWasiMain`): callback loop EXIT/YIELD/WAIT, both stream
directions COMPLETE (host sink/source), waitable-set, return-future — all e2e green, 3-host (ADR-0187 stackless, no
fibers; 0188 P3 runner; 0189 ζ2; 0190 host peers; 0191 WAIT path). Hardening: **D-337** future-drop-before-write
traps; **D-445 partial** async guest-faults → guest trap (not host panic). 18 async e2e fixtures green. Stackless
single-task CANNOT reach guest↔guest COMPLETION (lesson `2026-06-16-stackless-stream-completion-needs-host-peer`;
needs a scheduler/buffering — front ② item). (D-444 = p2-async file split deferred; D-445 remainder = host-FAILURE
error contract, ADR-grade.)

**NEW DIRECTION (4-front async-maturity + completion campaign).** Reference clones updated to latest 2026-06-16:
wasmtime @06-13 (`tests/misc_testsuite/component-model/async/` ~44 `.wast`); WASI @0.3.0 release; **wasi-testsuite
cloned** (`tests/rust/wasm32-wasip3`); wasm-tools/component-model refreshed (`implements.wast` new). Order ②→①→③→④:
- **② wasmtime async .wast gap-mining (ACTIVE — highest ROI)**: gap matrix in `private/notes/p17-wasmtime-async-gaps.md`.
  **DONE**: Gap A (`afcf889a`) — an async export declaring a result MUST call task.return before EXIT, else trap
  (`task-return-traps.wast`); `driveAsyncMain` checks `ctx.task_return` when `asyncExportExpectsResult`. copy-requires-
  IDLE (`05b35c28`): `StreamFutureEnd.copy` traps (CopyNotIdle→guest trap) on a non-IDLE end — 2nd concurrent copy or
  copy on a DONE end (spec `stream_copy`/`future_copy` `trap_if(state!=IDLE)`, `trap-if-done.wast`). **VERIFY
  EACH ROW vs spec** (lesson `2026-06-16-gap-matrix-subagent-verify-against-spec`): the matrix's "cancel-not-copying
  → returns 0" was WRONG (CanonicalABI `cancel_copy` traps; our `async_cancel_no_copy` already correct). NEXT:
  **front② TIER-1 DONE**; deferred **D-446** Gap B + **D-447** TIER-2/3 (design-grade). **front① = path ② (plain
  rust wasip3) — TOOLCHAIN RESOLVED + BAKED**: `flake.nix devShells.gen-wasip3` + `$ZWASM_WASIP3_RUSTFLAGS` build a
  real rust wasip3 component hermetically (nightly `-Z build-std` + `wasm-component-ld --wasm-ld-path` nixpkgs
  wasm-ld + `link-self-contained=no` w/ stable wasip2 crt1/libc; pinned nightly 2026-06-14, reproducible). **VERIFIED:
  zwasm runs the output → exit 1** (cli-exit). Recipe: lesson `2026-06-16-wasip3-hermetic-build-recipe`; caveats in
  D-448. **wasip3 conformance corpus — 7 fixtures GREEN** (…`32719a76`/`b4a5b66d`):
  cli-exit + cli-stdout + cli-stderr + cli-env + cli-args + cli-stdin + cli-clocks (exit + 3 stdio + env + argv +
  wasi:clocks), real rust wasip3 components via `test/component/wasip3/` + `scripts/gen_wasip3_fixtures.sh`. That caps
  the **plain-std-reachable** surface (filesystem needs preopens; random needs a non-std crate). **D-449 RESOLVED — false alarm,
  not a runtime bug**: env/args/stdin ARE delivered; the "empty input" was a fixture flaw — `wasi:cli/exit` is
  `func(status: result<_,_>)` (ok/err only), so a guest `exit(N>0)` collapses to exit_code 1, making an `exit(42)`
  success-sentinel unsatisfiable (subagent-instrumented: p2GetEnvironment called once, envs.len=1, bytes correct).
  Lesson `2026-06-16-wasi-cli-exit-result-channel-fixture-trap` (signal success via exit(0)/stdout, never a numeric
  code). **front① cli+clocks conformance DONE (7 fixtures).** **front ④ perf LAUNCHED (measure-first done → D-450)**:
  the all-engine matrix shows zwasm-jit vs wasmtime clusters ~1.5–4× (single-pass tradeoff) EXCEPT **shootout/base64
  at 13.6×** (781 vs 57 ms; all optimizing comparators ~60-80 → zwasm-specific hotspot) = the highest-ROI target.
  **NEXT**: D-450 Phase-I — profile base64's hot loop under `--engine jit` (`ZWASM_DEBUG=jit.dump` + Recipe 18; suspects
  = unreduced div/mod for /3,%3,/4, table-lookup load8 addressing, byte mask/shift spills), then a single-pass-bounded
  fix (§1.3/§3.2, NO optimising tier). matrix/keccak (3.7-3.9×) secondary. ROI-first — only fix a cheap single-pass win.
- **① WASI 0.3 conformance**: compile wasi-testsuite `rust/wasm32-wasip3` via `.#gen` (add wasm32-wasip3 target + wit
  deps), run as a conformance corpus.
- **③ real-world corpus 50→100**: add MoonBit/Grain/Kotlin (Wasm-GC) + AssemblyScript/Swift/Zig toolchains to
  `.#gen`, web-search real programs, compile+run. Folds in D-329/D-026/D-074/D-082 (corpus/provisioning debt).
- **④ perf rework (ADR-0153, single-pass-bounded)**: measure benches regressed by feature additions; optimise within
  §1.3/§3.2 (no optimising tier). Goal = lightweight-fast + no regression, NOT beating Cranelift/LLVM.

## Active bundle

- **Bundle-ID**: p17-async-maturity-4front (②wasmtime-gaps → ①wasip3-conformance → ③corpus-100 → ④perf-rework)
- **Cycles-remaining**: many (multi-front; ② DONE, ① DONE 7 fixtures, ④ perf active, ③ corpus deferred)
- **Continuity-memo**: ② DONE (Gap A `afcf889a` + copy-IDLE `05b35c28`; D-446/D-447 deferred). ① DONE — real rust
  wasip3 corpus (cli-exit/stdout/stderr/env/args/stdin/clocks, 7 green) via the hermetic `.#gen-wasip3` recipe; built
  the toolchain from scratch (nightly+build-std+nixpkgs-wasm-ld+wasip2-libc, lessons `2026-06-16-wasip3-hermetic-build-
  recipe` + `…-wasi-cli-exit-result-channel-fixture-trap`); D-449 was a fixture false-alarm. **④ perf active**: D-450
  = profile shootout/base64 (13.6× wasmtime, the outlier) under `--engine jit`, single-pass-bounded fix. ③ corpus
  (MoonBit/Grain/Kotlin/AssemblyScript toolchains) deferred — heavy new-toolchain setup, lower priority than ④.
- **Exit-condition**: (front ④) base64's jit/wasmtime ratio brought toward the ~1.5–4× single-pass baseline via a
  measured single-pass fix (D-450 Phase I–V), OR ROI shown insufficient + documented; full bench re-profile recorded.

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
