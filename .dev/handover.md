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
  Wasm-GC source-lang programs** (GC backend exercised only by hand-written spec `.wat`). **Hoot probe RAN — paid off
  like the AS probe**: a dense-GC Hoot module (struct.new 758 / array.new 360 / ref.cast 2074 / ref.i31 2858) failed
  zwasm VALIDATION at func #36 on `return_call`, surfacing **2 real validator spec bugs FIXED + 1 latent**: (1)
  `return_call*` result check used exact eql not subtyping (`9064faa5`); (2) `table.copy` same class (`480809af`);
  (3) `br_table` labelTypesEq pairwise-eql too strict → **D-452** (restructure, latent, not yet a real blocker).
  Lesson `…-validator-exact-eql-where-reftype-subtyping-required` (audit recipe: grep `.eql(` in validator, classify
  numeric-vs-reftype). Hoot import surface is MODERATE+stubbable (~36 imports, ns `rt`/`io`/`debug`; `bignum_*` dead
  for fixnum programs — far lighter than the "Hoot needs full JS reflect" reputation, via `import-abi? #f`).

## Active bundle

- **Bundle-ID**: p17-③-gc-corpus (real Wasm-GC source-lang fixtures to stress the GC backend)
- **Cycles-remaining**: several (new-toolchain integration like wasip3 was)
- **Hoot bring-up — validator bug chain (each blocker = a real spec fix; wasm-tools validates the whole module)**:
  Four validator/decoder spec bugs found+FIXED by the probe: func#36 return_call subtype (`9064faa5`), table.copy
  subtype (`480809af`), func#84 canonical-equality (`9ec68a75`), func#354 **D-453 heap-type SLEB decode / concrete
  idx≥64** (`c528c3b3`). D-453 was the big one: ref.test/cast/br_on_cast read the heap-type immediate as 1 byte but
  it's SLEB128 (idx≥64 = 2+ bytes) → decoder desync → false UninitializedLocal 3 hops downstream. Fixed across
  validator+lower+ref_test_ops+mvp+both-arch JIT (encoding: abstract/idx<64 = bare byte unchanged; idx≥64 =
  0x8000_0000|idx; JIT null-flag bit8→bit30; +x86_64 `&0xFF` truncation fixed). 2 regression fixtures + lesson
  `leb-decode-desync-manifests-far-downstream`. **The Hoot module now passes validation + lowering cleanly** and
  reaches INSTANTIATION, where it correctly fails on unsatisfied `rt`/`io`/`debug` imports (~36 — the D-451 strict
  reject). **③ DECISION POINT**: to RUN a real Hoot program needs a host-import shim (a Scheme runtime: bignum/
  wtf8-string/io/quit leaf prims) — a sizable undertaking. The probe's PRIMARY value (4 real GC spec-conformance
  fixes the synthetic suite missed) is banked + the new edge fixtures (canonical_eq, ref_cast_concrete_idx64,
  ref_test_null_idx256) ARE real GC programs running green. NEXT: weigh (a) build the Hoot host-shim to land a
  running real-world wasm-gc fixture vs (b) accept the validator-hardening payoff + close the bundle on the
  hand-derived GC fixtures + dart2wasm probe. Likely (b) unless the shim is small.
- **Continuity-memo**: ②①④ DONE. ③ active — Hoot chosen (lean import surface; dart2wasm needs heavy JS glue,
  deprioritized). Probe already found+fixed 2 validator bugs (`9064faa5`/`480809af`). **NEXT = re-run the Hoot module
  under zwasm** now return_call validates; expect next blocker = D-452 (br_table) OR an unsatisfied `io`/`rt` import
  → write a tiny host stub (write_stdout/quit + bignum identity shims), then bake `.#gen-gc` shell +
  `scripts/gen_gc_fixtures.sh` (mirror the wasip3 recipe) + commit fixtures under `test/realworld/wasm/`. Spike:
  `/tmp/hoot-spike` (prog.scm/wasm/wat + compile.scm; recipe = guile w/ Hoot `GUILE_LOAD_PATH`, `(hoot compile)`
  `compile-file #:import-abi? #f`).
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
