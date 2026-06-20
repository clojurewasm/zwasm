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

- **Bundle-ID**: D-477-jit-multiarg-invoke
- **Cycles-remaining**: ~1 (core done; residual = niche debt)
- **Continuity-memo**: **D-477 CORE COMPLETE + runtime-verified ALL 3 ARCHES** (arm64
  native / x86_64 SysV Rosetta / Win64 windows-gate OK). GPR + FP + ref multi-arg, single
  result (`invoke`/`runWasiLenientArgs`) + MULTI result (`invokeMulti`, incl 2-arg×2-result
  @6d750b5a9). Generic two-bank wrapper-thunk (emitAarch64 ≤7 / emitX8664SysV ≤5 /
  emitX8664Win64 ≤3) replaced the shape helpers; CLI `--invoke add=2,3`→5 interp-parity.
  All SHAs + designs in debt **D-477 (now `partial`)** + `private/notes/`. **CLI multi-RESULT print DONE
  @eb573e13a** (swap2=7,9→"9\n7\n", arm64+SysV; runWasiLenientArgs multi_out + typedResultToVal).
  **RESIDUAL = 2 NICHE slivers** (build on demand): (1) v128 args (model-A 2-slot decided,
  Win64-by-ref gotcha — `private/notes/` §Slice 3) — **next sliver if continuing D-477**;
  (2) Win64 ≥4-param stack-spill (rare).
- **🔭 RECOMMENDATION (for user steer)**: D-477 core unblocks the **ADR-0200 API-JIT phase**
  (the user's stated priority). The 3 slivers are niche + debt-tracked + do NOT gate the API.
  Recommend PIVOT to the API phase now; build slivers on demand. (Honoring the literal "完遂
  first" directive ⇒ default next = sliver (1) CLI multi-result-print; user may redirect to API.)
- **Exit-condition**: MET (CLI add=2,3 = interp @b88435743) + core matrix runtime-verified.
- **Pre-worked design (先読み)**: all 4 slices designed in `private/notes/d477-remaining-slices-design.md`
  (Win64 register-only ≤3-param collapse + reorder, FP two-bank assignment, v128 16B-slot
  ADR sub-decision, multi-result via invokeMulti). ADR-0200 §"API shape" now carries the
  wasmtime/wasmer peer 裏取り (EngineKind{auto,jit,interp}, auto→JIT, interp-fallback on
  JIT-less arch, C untyped + Zig typed sugar, caller-pre-sized multi-value).
- **cljw dogfooding OBLIGATION (don't forget across sessions)**: when the ADR-0200 JIT-backed
  API is embedder-stable, send `private/dogfooding_handover/to_cljw_NN.md` = engine-selection
  shape + invoke arity/type matrix + embedder-contract deltas + pin SHA (from_cljw_01 CONSUMED,
  reqs folded into ADR-0200; memory `project_cljw_dogfooding_mailbox`). Mailbox cadence: check
  `from_cljw_*` for `SENT` at unit boundaries (after a commit). Engine select = per-instance,
  interp MUST coexist (cljw dual-engine diff oracle).

## RESUME POINTER (2026-06-20) — for a fresh session

**🎯 D-477 (memory `feedback_ai_invented_by_design_not_sacred`)**: CORE COMPLETE — GPR+FP+ref multi-arg,
single+multi result, all 3 arches runtime-verified (debt D-477 `partial`). 3 niche slivers remain (CLI
multi-result-print / v128-args / Win64-≥4-stackspill). **RECOMMEND pivoting to the ADR-0200 API phase**
(user priority; slivers don't gate it). Default-if-unsteered = sliver (1) CLI multi-result-print.
**PARENT ARC = ADR-0200** (user 2026-06-20): D-477 is the gating #1 of "JIT-backed embedding API, JIT-DEFAULT,
selectable" — interp-only-API was an UNRATIFIED AI deferral, now reversed (SIMD is JIT-only → unrunnable via API).
After D-477: PRIORITIZED API-JIT phase = peer 裏取り (wasmtime Config/Strategy) → API design → impl → first-party
mini-consumer test (C + Zig embedder calling multi-arg + v128 export; NOT cw — that's cw's responsibility).

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
