# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state — Phase 17 完成形 completion-refinement (release = USER-ONLY, ADR-0156)

Project at the **完成形 plateau** (all dims confirmed): clean (C/Zig/CLI audits), full-featured (WASI complete +
now cross-component STRING composition, D-305 milestone), 100% spec (`test-spec` 25539/0), lightweight-yet-fast
(v1-JIT parity, D-265 closed). Robustness: interp+JIT fuzz 0 crashes. Closed-arc detail lives in git/ADRs/lessons.

**Closed arcs (detail in git/ADRs/debt — do NOT re-walk)**: D-305 cross-component linker (string/list/record
marshalling both directions, ADR-0196, comp-assert 170/0); ADR-0195 guest↔guest async FUNCTIONALLY COMPLETE +
D-463 handle isolation (ADR-0197); D-034 SIMD spill-completeness CLOSED @411dd1e14; wasi:random, D-335 typed
marshalling, C-API Windows-export. Residual long-tails (debt-tracked, do NOT grind): D-464 async adversarial,
D-305 niche shapes. Version `2.0.0-alpha.3`. Low-pri follow-up: consolidate duplicated SIMD spill helpers.

## Active bundle

- **Bundle-ID**: ADR-0200-jit-backed-embedding-api
- **Cycles-remaining**: ~5 (SIMD/v128 arm → accessors → host-import bridge → C-path + sandbox →
  mini-consumer → cljw signal)
- **Continuity-memo**: **First increment LANDED @7bfc49c8d** — `InstantiateOpts.engine:
  EngineKind{auto,jit,interp}`; `.jit` forks `instantiateFacade`→heap-pinned `runner.JitInstance`
  (new Zone-1 `Instance.jit: ?*anyopaque`, interp `runtime==null`); Zig-facade `invoke` JIT arm
  (`JitInstance.exportFuncSig` + scalar arg→u64 marshal + `trap_kind`→facade `Trap` map); new
  `InvokeError.UnsupportedEngineSignature` for uncovered shapes. Scope = no-import scalar exports;
  `.auto` STILL→interp pending host-import bridge (TODO in `instantiateFacade`, defer-not-workaround).
  Green @full unit suite (3061/3074, 0 fail). **NEXT slices (impl map `.dev/adr0200_api_impl_map.md`
  §"Accessor blast radius"/§"Host imports")**: (a) **SIMD/v128 + multi-result arm** via
  `JitInstance.invokeMulti`/`TypedResult` (the headline — must be JIT per user constraint); (b)
  facade accessors `runtime==null` JIT arms (memory/global/table/fuel/interrupt setters — replace the
  D-314-seam `assert(runtime!=null)`); (c) host-import→JIT bridge + WASI (`func_import_targets` +
  `rt.wasi_host`), then flip `.auto`→JIT; (d) C-path `wasm_func_call` JIT arm + `wasm_instance_new`
  engine knob; (e) D-314 sandbox sign-off; (f) mini-consumer + cljw signal.
- **Exit-condition**: first-party mini-consumer (C via `include/zwasm.h` + Zig via `src/zwasm/*`)
  instantiates engine=jit, calls a multi-arg AND a v128/SIMD export, asserts results; engine-knob
  default documented; cljw readiness signal sent (`to_cljw_NN`). NOT cw — that's cw's responsibility.
- **cljw dogfooding OBLIGATION (don't forget across sessions)**: when the ADR-0200 JIT-backed
  API is embedder-stable, send `private/dogfooding_handover/to_cljw_NN.md` = engine-selection
  shape + invoke arity/type matrix + embedder-contract deltas + pin SHA (from_cljw_01 CONSUMED,
  reqs folded into ADR-0200; memory `project_cljw_dogfooding_mailbox`). Mailbox cadence: check
  `from_cljw_*` for `SENT` at unit boundaries (after a commit). Engine select = per-instance,
  interp MUST coexist (cljw dual-engine diff oracle).

## RESUME POINTER (2026-06-21) — for a fresh session

**🎯 ACTIVE = ADR-0200 JIT-backed embedding API** (user-steered pivot 2026-06-21; D-477 core DONE/closed,
niche tails = build-on-demand debt). Per-instance engine selection, **JIT-default**, interp coexists.
See `## Active bundle` + ADR-0200 (§"API shape" + §"Consuming requirements"). Smallest increment DONE
@7bfc49c8d (Zig-facade `engine=.jit` opt-in, no-import scalar invoke). NEXT = SIMD/v128 + multi-result
arm (`invokeMulti`/`TypedResult`), then facade accessors `runtime==null` arms, host-import→JIT bridge
(+`.auto`→JIT flip), C-path `wasm_func_call` arm, D-314 sandbox sign-off, mini-consumer, cljw signal.
D-477 invoke matrix is the substrate; impl map `.dev/adr0200_api_impl_map.md`.

**STANDING DIRECTIVE = CORRECTNESS SWEEP** (user 2026-06-20, memory `feedback_correctness_sweep_phase`): high-value
bar OFF. Sweep toward 0% the 3 gap classes — (1) wasmtime-works-zwasm-doesn't, (2) wasm/wasi spec non-conformance,
(3) instability/crashes — easiest-first, TDD + 3-host, repeat; don't ask "is this high-value." Status: spec
skip-impl=0, realworld JIT 56/56 GATING (`test-realworld-diff-jit`), no UnsupportedOp crash, fuzz 0-crash. The
D-477 bundle is the live front; prior sweep closures (D-468/D-469/D-470/D-475/D-476/extended-const/GC trap-kind/
memory64+SIMD/fuzz exec-differential) are in git/lessons — do NOT re-walk.
**VERIFICATION LESSON (operationally live)**: a JIT-codegen fix MUST be checked with `test-spec-wasm-2.0-assert`
on BOTH arm64 AND `-Dtarget=x86_64-macos` — NOT `test-spec`(interp)/`zig build test`(unit).
**D-475 table64 slice 4 (JIT table64 codegen) PARKED** (structural u32→u64 descriptor widening, Win64-risk; bounded
4-cycle bundle in debt row, PERF not correctness). Self-contained table64 interp-conformance DONE.

**Phase 17 完成形 plateau** (validated — do NOT re-walk): async COMPLETE; v128 spill (D-034/D-460/D-461) CLOSED;
surface audits clean 2026-06-18; fuzz 0-crash; realworld JIT run 56/56 byte-match wasmtime (gating). NOT-WORTH: D-294-R2 TrapKind.

**Recently CLOSED (detail in debt/git/lessons)**: const-expr evaluators extracted to instantiate_const_expr.zig
@d9dbe7234 (marker's planned move; instantiate.zig 2014→1626, marker removed); D-467 simd invoke-boundary skips;
D-305 cross-component AGGREGATE marshalling (record-with-string both directions, comp-assert 170/0).

**Step-0.7 NOTE**: `failed command: test…--listen=-` is COSMETIC (exits 0); trust `[run_remote_*] OK/FAIL` + `N
passed, 0 failed`, not that line.

**PARKED / gated (do NOT speculatively grind)**: D-305 long-tail (list<record>/variant/multi-param — niche, +
`component_graph.zig` 1895/2000 file-split first); D-464 async; 21 `blocked-by` (upstream/proposal/time-gate/corpus).

## Closed arcs (detail in ADRs/git/debt)

- D-305 STRING milestone (@4cceeb1e, ADR-0196) · doc-inventory fresh (`42441634`) · ADR-0192 wasmtime differential
  (9+6 engine bugs fixed; residual D-209/D-456 parked) · 4-front async-maturity (wasmtime async .wast, wasip3, perf
  ROI-rejected D-450, GC corpus 6 bugs) · WASI 0.3 core DONE (D-335, ADR-0187-0191). **validator.zig at 3449/3450
  cap — NEXT validator edit MUST extract per the file's marker plan.**

## Long-tail (debt-tracked / parked — NOT active; see debt.yaml)

- **JIT-correctness** (front B): D-331(B) CLOSED @adb7b99a · D-330 c_sha256 PROVABLY-BLOCKED (bucket-2) ·
  D-331(A) go runtime-corruption (DRIVABLE; build mem-divergence diff first) · D-333 (folds into D-330). Corpus
  interp-green; run-stage opt-in. Trace: `ZWASM_DEBUG=jit.dump` + `scripts/jit_value_trace.sh` (Recipe 18).
- **D-454** (future-bucket): real GC-language program execution fixture, blocked on Hoot reflect-ABI host port.

## State (all 3-host green @046d9c67/win @886d0667; release = USER-ONLY, ADR-0156)

- **Wasm 1.0/2.0/3.0**: 100% spec, 0 skip (GC 362/0). **WASI 0.1** complete; **0.2/CM** default-ON (corpus 158/0/0);
  **0.3 core** done. Sandboxing triad everywhere.
- **Surfaces**: C-API 293/293 · Zig-API complete (full WASI parity) · lean CLI · memory-safety sound · dogfooded into
  cw. Runners ReleaseSafe (ADR-0177; `check_releasesafe_runners.sh`).
- **EH**: cross-instance JIT EH on BOTH arches (arm64 `4f73d9ee` + x86_64 `c534afca`). Interp + JIT EH corpus green.
- **Debt**: 62 entries; **ZERO `now`-class** (D-034 spill arc CLOSED @411dd1e14 → `note`; D-460 v128-GC + D-461 +
  D-293 + D-294 all `note`). Remaining partials: D-305 (consumer-gated CM shapes), D-331(A)/D-330 (go_* JIT; B closed).
  Rest front-tagged (future-bucket/parked); D-462 feature-separation = user-gated. **完成形 plateau.**
- **Realworld corpus**: 56 fixtures (c/cpp/emcc/go/tinygo/rust/zig), interp 56/0; JIT run-stage opt-in.
- **Tag**: `v2.0.0-alpha.3` tag-only (no Release → Latest stays v1.11.0), USER-ONLY.

## Key refs

- [`flake.nix`](../flake.nix) `devShells.gen` / `.#gen-wasip3` — fixture toolchains. [`docs/zig_api_design.md`](../docs/zig_api_design.md).
- ADRs: **0156** (NO autonomous release) · **0153** (rework) · **0187-0191** (CM-async) · **0185** (x86_64 EH) ·
  **0099** (file-size caps) · **0126** (iso-recursive canonical equality).
- lessons INDEX: `.dev/lessons/INDEX.md` (keyword index for Step 0.4).
