# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state — Phase 17 完成形 completion-refinement (release = USER-ONLY, ADR-0156)

Recent closed arcs (3-host or ubuntu-verified; full detail in git/lessons): **D-457** SIMD systemic close (24805/0) ·
**D-458** core-2.0 corpus completeness + cross-corpus audit · doc-inventory pass · **C-ABI trap-kind drift guard** ·
**D-455** array-alloc dedup · **D-459** Wasm 3.0 §3.3.1 local definite-assignment (restore-at-end NOT intersection) ·
**win-specassert-pass0 (ADR-0174 Phase-1) CLOSED**: windowsmini wasm-3.0-assert pass=0 root-caused to CRLF — the
runner was the lone one not trimming `\r`, so windows-CRLF manifests gave `module_path` ending `\r` →
`error.BadPathName` → all modules silently un-loaded. Fixed @02592aa8 (trim, mirrors 4 other runners) → **windows
now pass=10234 = ubuntu, 0 MODULE-READ-FAIL, VERIFIED**; + @b1606384 gates the runner on fails (closes the
"OK-hides-pass=0" masking; lesson `windows-crlf-manifest-badpathname-hidden-by-nongating-skeleton`). D-458 RESIDUAL
(note): broad regen non-idempotency. Ratchet baseline 24 loose (real 22) — harmless. Stale-doc: ROADMAP §16.7 D-277.

CLI surface audit (@4e5e42fe): code↔`--help` fully consistent. Gate change @b1606384 **VERIFIED GREEN on BOTH hosts**
(windows `[run_remote_windows] OK.` wasm-3.0-assert pass=10234 fail=0 / simd 24805/0 / spec 25539/0; ubuntu OK
@f1a1d503). win-specassert campaign fully closed; the fail-gate is clean.

**Multi-task async campaign OPENED then PARKED** (this turn, ADR-0195 Revision): a Phase-II design check (before
any scheduler code) found guest↔guest stream completion is **blocked-by D-305** (component linker), one layer
deeper than Phase I assumed. CM-async creates a subtask ONLY via an async-lowered import to a GUEST callee in
ANOTHER component instance (cross-component) — but zwasm's async imports are host-only (name-match), `Subtask` is
built-but-UNWIRED, and there's NO intra-component multi-task path. The scheduler is the layer ABOVE D-305; building
it now = speculative infra (spike §2, no consumer). **Retained**: Phase II(a) single-task `AsyncDeadlock` char test
(`80ec1f63`, permanent guard). ADR-0195 design stands for when D-305 lands; lesson
`2026-06-17-guest-guest-async-is-downstream-of-component-linker`. The ADR-0153 design-gate caught this, saving
~400 LOC. Prior arcs: fuzz campaign 808 mods 0 crashes; bounded 完成形 vein plateaued (WASI sync surface, C-API
@b4d75506, decoder, CLI clean); wasi:random COMPLETE; ADR-0193 follow-up + version SSOT; D-335 typed marshalling DONE.

**Plateau confirmed across ALL 完成形 dimensions** (this turn): clean (C/Zig/CLI surface audits done), full-featured
(WASI complete bar consumer-gated big async/composition), 100% spec (`test-spec` 25539/0), lightweight-yet-fast
(v1-JIT parity met/exceeded, D-265 closed — `bench/results/s15p_parity_vs_v1.md`). Robustness re-verified: fuzz 808
mods 0 crashes on BOTH interp AND **JIT** codegen; README/docs/flags drift-clean.

**D-305 component-composition campaign OPEN — Phase I scoped via RED fixture** (this turn). Authored
`strlen_graph.wat` (2-component graph, B exports `firstbyte(s:string)->u32=s[0]`, A builds "Z" + calls it → must
return 0x5A). It exposed the REAL first barrier: `instantiateGraph` (`component.zig:470` `firstCoreModule`) compiles
only the FIRST core module per child, so a realistic 2-module child (libc + main) never instantiates `run` →
`error.ExportNotResolved`. So the fully-general linker is genuinely multi-cycle (matches "disproportionate effort").
See `## Active bundle`. ADR-0193 (P1-P4, D-462) + D-461 (ADR-0194) CLOSED (below). **windowsmini gating RESUMED**
(batch a3b04e57 green). Version `2.0.0-alpha.3`.

## Active bundle — D-305 fully-general component linker (component composition)

- **Bundle-ID**: d305-component-linker
- **Cycles-remaining**: ~5-8 (genuinely multi-cycle; disproportionate-effort per debt)
- **Continuity-memo**: RED fixture `test/component/strlen_graph.{wat,wasm}` ready (asserts `run()==0x5A`; its test
  is UNWIRED — can't commit a failing test, wire it WITH the green impl). Incremental TDD plan: **(1) FIRST**
  multi-core-module / multi-core-instance graph linking — `instantiateGraph` (`component.zig:437-496`) currently
  compiles only `firstCoreModule` + name-matches flat func imports; rework to iterate the child's core instances,
  resolve each `(with ...)` arg (incl. canon-lowered import instances + the libc memory export). Author a FLAT
  2-module-per-component fixture (libc + main, flat-u32 args) as the RED for THIS step → green (lifts the
  "one-core-module-per-child" limit, no marshalling yet). **(2) THEN** canon lower→core→lift cross-component STRING
  marshalling at the boundary (A-mem→B-mem copy; reuse the host-boundary canon machinery WASI already has) → wire
  strlen_graph test → green. File an ADR (§10-area component-boundary canon lift/lower) at step (2) design. Key
  files: `src/api/component.zig` (`instantiateGraph`/`ComponentGraph`/`invokeFlat`), `feature/component/canon.zig`
  (lift/lower), `feature/component/ctypes.zig` (component_instances / canons). D-305 debt has the pinned scope.
- **Exit-condition**: `strlen_graph` test green (a STRING marshals across the component boundary, `run()==0x5A`),
  AND `adder_graph` (flat) + the full component corpus stay green.

## D-461 regalloc-origin rework (ADR-0153/ADR-0194) — CLOSED Phase I-V 2026-06-16

CLOSED: x86_64 regalloc v128-spill OOB (`regalloc.zig:222`) fixed — three inconsistent spill-frame origins unified
by threading per-arch `max_reg_slots_gpr` into `computeSpillOffsets` (ADR-0194; impl `3cd2ede6`). Verified arm64
2922 green + x86_64-Rosetta rc=0. Full detail: ADR-0194 + lesson `x86_64-regalloc-fp-spill-origin-mismatch`.

## D-461 SIMD v128-spill — high-value DONE (3-host green); result-write remainder = tracked debt (exotic)

**DONE both arches, 3-host green**: regalloc-origin rework (ADR-0194, Win64-verified @8f4f88c5) + all 6
extract_lane + all 4 bitmask widths. Concrete D-460 blocker CLEARED. **Result-write remainder is now TRACKED DEBT
(D-461)**, not active: Extend/Extadd/replace_lane/binop-dsts — arm64 unops ALREADY spill-aware (shared
`emitV128Unop`), so it's **x86_64-only** but needs `spill_base_off` threaded through ~26 sig sites per category +
per-op scratch-XMM audit (LANDMINE). EXOTIC (high-v128-pressure only). Full per-op scope + the reusable fixture
recipe (`.wat` → `wasm-tools parse`, build the or-chain programmatically) are in the D-461 debt row. Re-open as a
focused bundle if a real program needs it.


## Closed/paused (detail in git + debt.yaml)

- **doc-inventory freshening DONE** (`42441634` README + ADR-0193 P4 doc-sync): reader-facing surfaces clean
  (C-API 293/293, component 158/0/0, Wasm 2.0 skip-impl==0, 3.0 all-9-proposals, version anchors retired).
- **ADR-0192 wasmtime differential campaign — paused**: goal met (9 real engine bugs fixed via wasmtime
  misc_testsuite + 6 SIMD via D-457). Residuals: **`D-460`** v128-GC (arm64 struct/array get/set EMIT DONE
  `f79a3ced`/`41015a9b`; array.new_fixed/copy + x86_64 mirror unblocked NOW by the D-461 spill fixes in progress),
  **`D-209`** memory64 >4 GiB offset, **D-456** host-import fixtures (parked). Harness `scripts/wasmtime_misc_*.sh`.

**Closed campaigns (detail in git/lessons)**: prior 4-front async-maturity (2026-06-16) — ② wasmtime async .wast
TIER-1 (`afcf889a`/`05b35c28`; D-446/447 deferred), ① wasip3 conformance (7 real-rust fixtures, `.#gen-wasip3`),
④ perf (ROI-rejected single-pass ceiling, D-450), ③ real-world GC corpus (6 engine bugs FIXED: D-451-453/9064faa5/
480809af/9ec68a75/79742cb4; 4 GC edge fixtures; real Hoot execution → D-454). **WASI 0.3/Preview-3 core DONE**
(D-335; ADR-0187-0191). validator.zig at 3449/3450 cap — NEXT validator edit MUST extract per the file's marker plan.

## Long-tail (debt-tracked / parked — NOT active; see debt.yaml)

- **JIT-correctness** (front B / parked): D-330 c_sha256 `\n` (parked — conflicting-constraint; do NOT re-run the
  blanket fix) · D-331(A) go runtime-corruption (infra-blocked) · D-331(B)/D-289 go_regex emit (parked) · D-333
  (br_table, folds into D-330). Realworld corpus interp-green; JIT run-stage opt-in (`ZWASM_JIT_RUN=1`). Trace:
  `ZWASM_DEBUG=jit.dump` + `scripts/jit_value_trace.sh` (Recipe 18).
- **D-454** (future-bucket): real GC-language program execution fixture, blocked on Hoot reflect-ABI host port.

## State (all 3-host green @046d9c67/win @886d0667; release = USER-ONLY, ADR-0156)

- **Wasm 1.0/2.0/3.0**: 100% spec, 0 skip (GC 362/0). **WASI 0.1** complete; **0.2/CM** default-ON (corpus 158/0/0);
  **0.3 core** done. Sandboxing triad everywhere.
- **Surfaces**: C-API 293/293 · Zig-API complete (full WASI parity) · lean CLI · memory-safety sound · dogfooded into
  cw. Runners ReleaseSafe (ADR-0177; `check_releasesafe_runners.sh`).
- **EH**: cross-instance JIT EH on BOTH arches (arm64 `4f73d9ee` + x86_64 `c534afca`). Interp + JIT EH corpus green.
- **Debt**: 61 entries; `now`-class = D-462 (feature-separation, ADR-0193, user-gated), D-460 (v128-GC partial),
  D-461 (SIMD-spill, blocks D-460). D-335 (WASI 0.3 core) DONE. Rest front-tagged (future-bucket/parked).
- **Realworld corpus**: 56 fixtures (c/cpp/emcc/go/tinygo/rust/zig), interp 56/0; JIT run-stage opt-in.
- **Tag**: `v2.0.0-alpha.3` tag-only (no Release → Latest stays v1.11.0), USER-ONLY.

## Key refs

- [`flake.nix`](../flake.nix) `devShells.gen` / `.#gen-wasip3` — fixture toolchains. [`docs/zig_api_design.md`](../docs/zig_api_design.md).
- ADRs: **0156** (NO autonomous release) · **0153** (rework) · **0187-0191** (CM-async) · **0185** (x86_64 EH) ·
  **0099** (file-size caps) · **0126** (iso-recursive canonical equality).
- lessons INDEX: `.dev/lessons/INDEX.md` (keyword index for Step 0.4).
