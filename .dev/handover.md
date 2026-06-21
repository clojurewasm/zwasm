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

## RESUME POINTER (2026-06-21) — ADR-0200 JIT API delivered; `.auto`=interp (flip twice-reverted; dispatch matrix incomplete)

**ADR-0200 JIT API delivered; explicit `.jit` solid.** Dual-engine accessors @3d701ddaf + exportFuncSig @5b6449779
+ export_types-on-JIT @f68532e44 + FP/mixed 1-2arg invoke @d7da97e04/@3cf40a573 (cljw from_cljw_03/04). cap
api/instance.zig→3800. **`.auto` FLIP TWICE-REVERTED** (last @7dbdb973c; origin green) — each re-land's 3-host ubuntu
gate exposed x86_64 JIT gaps Mac masks (arm64 `.auto` falls back to interp). The flip = FORCING FUNCTION for x86_64
JIT hardening; see Active bundle. cljw aligned (to_cljw_05; default `.interp`).

## Active bundle

- **Bundle-ID**: jit-export-invoke-dispatch-matrix
- **Cycles-remaining**: ~3. **1/2-arg invoke matrix now COMPLETE** (@3cf40a573 — the veneer falls through to the
  generic buffer-write path on any uncovered combo; cljw mixed-2-arg fixed). **TOP REMAINING BLOCKER = D-489**
  (x86_64 JIT miscompile, tinygo_json) — NARROWED @34046a8a8 to an **x86_64 SPILL-PRESSURE bug** (only 4 GPRs;
  wrong scalar value under tinygo_json's ~65KB spill frame; iovec ptr Δ416/len wrong — NOT string-load). NEXT:
  value-trace (Recipe 18) the func issuing fmt write #2 → audit multi-spilled-operand handlers (emitSelectCtx/div-rem/
  wide-mul) + patchRel32 under >16-slot frames (x86_64/gpr.zig). Gates the flip re-land; then conformance-harness
  pinning + wide-shape `wrapper_thunk.emit` (D-477). cljw all-consumed (to_cljw_05).
- **Continuity-memo**: (survey-informed @a73ab393) 1-2 arg invoke uses the per-combo `dispatchScalar1/2`
  fast-path veneer (`runner.zig`); **uncovered combos now FALL THROUGH to `invokeViaBufferSingle` @3cf40a573**
  (cljw mixed (i32,f64)→f64 fixed). `dispatchScalar1` COMPLETE; **dispatchScalar2 FP DONE @d7da97e04**
  (0x03/0x28/0x2a/0x2e/0x3a/0x3c/0x3f). 3+arg/4+/multi-result fall through to the GENERIC path
  `invokeViaBufferSingle`/`invokeMulti` → `entry_buffer_write.invokeBufferWrite`, backed by per-arch ASM
  `wrapper_thunk.emit` (ADR-0106, `codegen/shared/wrapper_thunk.zig`) that marshals a `u64[]` buffer into
  GPR/FP banks. **THE GAP IS NOT MISSING DISPATCH — it's `wrapper_thunk.emit` shape coverage**: it returns
  `Error.UnsupportedOp` (→ `hasThunk(idx)=false` → `UnsupportedEntrySignature`) for: **Win64 >3 params, v128
  params/results (16B≠8B slot — explicit D-477 slice, wrapper_thunk.zig:185), some multi-result shapes**. f32/f64
  ARE supported. So `many-results/f` + wide `func--params/x` = `emit` didn't produce a thunk. **DONE this turn**:
  divbyzero `.jit` test @ac6733cd7 (basic JIT trap-kind surfacing CORRECT for covered shapes — so the wast
  divbyzero binding_error is a wide-shape thunk gap, NOT trap-mapping). **METHOD (next cycles, MEDIUM, arch-sensitive
  — VERIFICATION LESSON applies)**: widen `wrapper_thunk.emit` per-arch (emitAarch64:554 / emitX8664SysV:181 /
  emitX8664Win64:427) one shape at a time — Win64 >3 params, then multi-result FP, then v128 (D-477). Each: a `.jit`
  facade test reproducing (like addf), RED, widen emit + paired byte test, verify arm64 + `-Dtarget=x86_64-macos` +
  ubuntu. **RE-FRAMED @a5c281862**: 3-arg f64 invoke PROVEN to work on BOTH arches (committed test) → typical
  real-program shapes already ride the buffer path. The flip's ubuntu `^FAIL`s are NOT typical dispatch: (a)
  `many-results` = wasmtime's EXTREME stress (`f` returns **17 i32**, `f2` 17-param+17-result) — needs stack-spill +
  sret emit, the genuine hard D-477 slice, but ONLY appears in the conformance corpus; (b) `func--params` similar
  extreme; (c) `tinygo_json` realworld self-verify FAIL under `.auto`→JIT while `test-realworld-diff-jit` (direct JIT)
  is 56/56 — NOW CONFIRMED an **x86_64-SPECIFIC JIT MISCOMPILE = D-489** (CLI `--engine jit` on x86_64-macos
  mangles tinygo_json fmt output → `%!(EXTRA ...)`/`roundtrip: FAIL`; arm64-JIT + interp correct). The "56/56" missed
  it because the JIT RUN-stage is opt-in (`ZWASM_JIT_RUN=1`, run_runner_jit.zig:235) — x86_64 JIT realworld
  EXECUTION is under-gated. So the flip is a **forcing function exposing real x86_64 JIT correctness bugs**, not just
  harness routing. **SO THE FLIP RE-LAND PATH
  IS LIKELY NOT "implement 17-value emit"**: it's (1) **pin the interp-conformance harnesses** (`wast_runtime_runner`/
  wasmtime_misc_runtime — they test SPEC semantics; JIT conformance has its OWN runner `test-spec-wasm-2.0-assert`) to
  `.interp` by threading an engine param (the memo always said "pin interp-internal harnesses to .interp"); (2) fix the
  realworld_run `.auto` tinygo_json bug; (3) wide-shape emit stays D-477 debt until a REAL consumer needs >2 results /
  >register-count args (cljw doesn't). Next cycle: START with (1) — survey `wast_runtime_runner.zig` + realworld_run
  for how to pin engine, since that likely clears most ubuntu `^FAIL`s at once.
- **Exit-condition**: `.auto` flip re-landed (`git revert 7dbdb973c`) + interp-conformance harnesses pinned `.interp`
  + realworld `.auto` bug fixed, with **ubuntu x86_64 GREEN**. Until then `.auto`=interp. Wide-shape emit (17-value) +
  funcref `Table.set` @panic = non-blocking D-477/D-478 debt (no real consumer yet).

**STANDING DIRECTIVE = CORRECTNESS SWEEP** (user 2026-06-20, memory `feedback_correctness_sweep_phase`): high-value
bar OFF. Sweep toward 0% the 3 gap classes — (1) wasmtime-works-zwasm-doesn't, (2) wasm/wasi spec non-conformance,
(3) instability/crashes — easiest-first, TDD + 3-host, repeat; don't ask "is this high-value." Status: spec
skip-impl=0, realworld JIT 56/56 GATING (`test-realworld-diff-jit`), no UnsupportedOp crash, fuzz 0-crash.
ADR-0200 (JIT embedding API) + D-477 (JIT host-invoke) were the live fronts — both delivered/closed; the
ADR-0200 tail = D-478. Prior sweep closures (D-468/D-469/D-470/D-475/D-476/extended-const/GC trap-kind/
memory64+SIMD/fuzz exec-differential) are in git/lessons — do NOT re-walk.
**VERIFICATION LESSON (operationally live)**: a JIT-codegen fix MUST be checked with `test-spec-wasm-2.0-assert`
on BOTH arm64 AND `-Dtarget=x86_64-macos` — NOT `test-spec`(interp)/`zig build test`(unit).
**D-475 table64 slice 4 (JIT table64 codegen) PARKED** (structural u32→u64 descriptor widening, Win64-risk; bounded
4-cycle bundle in debt row, PERF not correctness). Self-contained table64 interp-conformance DONE.

**Phase 17 完成形 plateau** (validated — do NOT re-walk): async COMPLETE; v128 spill (D-034/D-460/D-461) CLOSED;
surface audits clean 2026-06-18; fuzz 0-crash; realworld JIT run 56/56 byte-match wasmtime (gating). NOT-WORTH: D-294-R2 TrapKind.

**Step-0.7 NOTE**: `failed command: test…--listen=-` is COSMETIC (exits 0); trust `[run_remote_*] OK/FAIL` + `N
passed, 0 failed`, not that line.

**PARKED / gated (do NOT speculatively grind)**: D-305 long-tail (list<record>/variant/multi-param — niche, +
`component_graph.zig` 1895/2000 file-split first); D-464 async; 21 `blocked-by` (upstream/proposal/time-gate/corpus).

## Closed arcs (detail in ADRs/git/debt)

- D-305 STRING (@4cceeb1e, ADR-0196) · ADR-0192 wasmtime differential (9+6 bugs fixed; D-209/D-456 parked) ·
  async-maturity (ROI-rejected D-450, GC corpus 6 bugs) · WASI 0.3 core (D-335, ADR-0187-0191). **validator.zig at
  3449/3450 cap — NEXT validator edit MUST extract per the file's marker plan.**

## Long-tail (debt-tracked / parked — NOT active; see debt.yaml)

- **JIT-correctness** (front B): D-331(B) CLOSED · D-330 c_sha256 PROVABLY-BLOCKED · D-331(A) go runtime-corruption
  DRIVABLE · D-333 folds into D-330 (all in debt.yaml; D-489 may share the go/x86_64 spill root). D-454 GC-program
  fixture future-bucket. Trace tooling: `ZWASM_DEBUG=jit.dump` + `scripts/jit_value_trace.sh` (Recipe 18).

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
