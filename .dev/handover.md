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

**4-front async-maturity + completion campaign.** Reference clones updated 2026-06-16 (wasmtime @06-13, WASI @0.3.0,
wasi-testsuite, wasm-tools). **②①④ DONE; ③ ACTIVE (GC-corpus).**
- **② wasmtime async .wast gap-mining — DONE (TIER-1).** Gap A (`afcf889a`): async export declaring a result MUST
  `task.return` before EXIT else trap. copy-IDLE (`05b35c28`): `StreamFutureEnd.copy` traps on non-IDLE end. Matrix:
  `private/notes/p17-wasmtime-async-gaps.md`; verify-each-row-vs-spec lesson. Deferred: **D-446** Gap B + **D-447**
  TIER-2/3 (design-grade).
- **① wasip3 conformance — DONE (7 fixtures GREEN).** cli-exit/stdout/stderr/env/args/stdin/clocks, real rust wasip3
  components via the hermetic `.#gen-wasip3` recipe (nightly `-Z build-std` + nixpkgs wasm-ld + wasip2 crt1/libc,
  reproducible). Caps the plain-std surface (fs needs preopens; random needs a crate). Lessons `…-wasip3-hermetic-
  build-recipe` + `…-wasi-cli-exit-result-channel-fixture-trap` (signal success via exit(0)/stdout, never numeric).
  D-449 was a fixture false-alarm. Caveats in D-448.
- **④ perf — DONE (ROI-rejected, accept the single-pass ceiling).** all-engine matrix: zwasm-jit ~1.5–4× wasmtime
  EXCEPT shootout/base64 13.6× (D-450). Profiled: base64 kernel = 59-68% spill traffic, only 8 GPRs. **Bulk class-B**
  (global-regalloc/LICM — single-pass can't close w/o the forbidden optimizing tier). Class-A peephole NOT contained
  (cross-op emit state in the D-265 subsystem) → high-cost/partial = ROI-insufficient. zwasm is "lightweight-fast
  within single-pass"; base64/matrix/keccak are the accepted §1.3/§3.2 tradeoff. D-450→note. Lesson `…-base64-single-
  pass-register-pressure-ceiling`.
- **③ real-world corpus 56→100 (ACTIVE).** Probe already paid off: **AssemblyScript surfaced + we fixed D-451**
  (`4c8c14fe`) — jit was LENIENT on unsatisfied imports (trap-on-call stub) vs interp's spec-correct instantiation
  reject; `runWasiLenient` now calls `assertWasiImportsSatisfied` (spec §4.5.4). **GC-stress (the user's core ③
  intent) — CORRECTED: Hoot + dart ARE in nixpkgs** (`guile-hoot` 0.8.0 Scheme→wasm-gc, `dart` 3.12.1 dart2wasm→
  wasm-gc) — NOT "heavy from-source". Corpus today: 56 fixtures (c18/cpp7/emcc3/go9/tinygo4/rust12/zig3), **zero
  Wasm-GC source-lang programs** (GC backend exercised only by hand-written spec `.wat`). **NEXT = runnability gate**:
  a real GC-lang module's host-import surface decides if zwasm can run it standalone (Hoot needs a reflect/runtime;
  dart2wasm needs JS glue). Investigating which (Hoot vs dart) yields a runnable-with-minimal-stub wasm-gc fixture.

## Active bundle

- **Bundle-ID**: p17-③-gc-corpus (real Wasm-GC source-lang fixtures to stress the GC backend)
- **Cycles-remaining**: several (new-toolchain integration like wasip3 was)
- **Continuity-memo**: ②①④ DONE (see above). ③ now active. Candidates BOTH in nixpkgs: `guile-hoot` 0.8.0
  (Scheme→wasm-gc; CLI is repl/server-only — compiler is the `(hoot compile)` Guile module, invoke via guile script)
  + `dart` 3.12.1 (`dart compile wasm`→wasm-gc, but imports heavy JS glue). Deciding factor = host-import surface
  (must be stubbable to run standalone in zwasm). Spike dir `/tmp/hoot-spike`. If runnable → bake a `.#gen-gc` shell
  + `scripts/gen_gc_fixtures.sh` mirroring the wasip3 hermetic recipe + commit fixtures under `test/realworld/wasm/`.
- **Exit-condition**: ≥1 real Wasm-GC source-language program (Hoot or dart) compiled hermetically + committed +
  running green under zwasm (interp at minimum), exercising struct/array/ref GC opcodes — OR documented impossibility
  (host-import surface too heavy to stub) with the evidence + a debt row for the alternative path.

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
