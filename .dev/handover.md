# Session handover

> ≤ 100 lines (soft) / 120 (hard). Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state — Phase 17 完成形 completion-refinement (release = USER-ONLY, ADR-0156)

Project at the **完成形 plateau** (all dims confirmed): clean (C/Zig/CLI audits), full-featured (WASI complete +
now cross-component STRING composition, D-305 milestone), 100% spec (`test-spec` 25539/0), lightweight-yet-fast
(v1-JIT parity, D-265 closed). Robustness: interp+JIT fuzz 0 crashes. Closed-arc detail lives in git/ADRs/lessons.

**D-305 cross-component linker — COMMON shapes ALL DONE + 3-host/x86_64-verified** (ADR-0196; detail in the
D-305 debt row + git): string/list params (@689040e6), string result (@184b5e05), `(string)->string` (@2b9b14ee),
boundary error-trap (@30bd1881, SECURITY — marshalling failures now TRAP, not silent-wrong). component_model
163/0; ubuntu OK @dfdcfdcf. Remaining rare shapes (record/result aggregates, >2-param arities) = consumer-gated
debt, do NOT grind speculatively.

**ADR-0195 guest↔guest async (multi-task scheduler) — FUNCTIONALLY COMPLETE 2026-06-17** (the D-335 last
functional gap; campaign closed-arc below). Cross-component async now works end-to-end: multi-task scheduler
(`driveScheduler`) → cross-component ROUTING (c-2b) → `task.return` capture + result round-trip (d-a/d-b-1) →
future rendezvous (d-b-2) → synchronous + BLOCKING multi-element stream rendezvous + pollSet/waitable-set delivery
+ AsyncDeadlock guard (d-c-1/d-c-2, @a82b4f84). Local gate green (test-all unit + comp-spec 163/0 + lint +
fallback). **D-463 cross-component async handle isolation CLOSED 2026-06-18 (@633189454, ADR-0197 ownership
ledger)**: a child can no longer reach a peer's un-granted stream/future end (adversarial isolation fixture
RED→GREEN). **Residual (debt-tracked, NOT blocking, do NOT grind): D-464** (broader (e) adversarial dropped/
cancelled cross-component cases + cancel-op/waitable wait-poll-drop graph builtins).

**Prior arcs**: wasi:random COMPLETE; ADR-0193 feature-separation + version SSOT; D-335 typed marshalling DONE;
C-API @b4d75506 (Windows export fix); interp+JIT fuzz 808 mods 0 crashes. ADR-0193 (D-462) + D-461 (ADR-0194)
CLOSED (below). **windowsmini RESUMED**. Version `2.0.0-alpha.3`.

## Active bundle

- **Bundle-ID**: D-034 SIMD spill-completeness cohort (scalar-operand sibling of D-461 + the v128-source arith gap)
- **Cycles-remaining**: ~1 (4 of 18 x86_64 int-arith (g) sites remain). DONE through @b870f146a — 15 sites incl.
  i8x16 shl/shr_u/shr_s + i64x2 shr_s @b870f146a (just-in-time reload). Templates: cmp/ne/extmul-low = 3-operand;
  extmul-high/i64x2 = dst/XMM15 load-temp; abs/neg = XMM7-park; LoadExtend/StoreLane single-operand→stage0; shifts =
  just-in-time reload (dst→home/XMM7, vec reloaded into dst each use). File-local helpers: resolveOrLoadV128 +
  storeV128IfSpilledLocal (op_simd_int_cmp_lane.zig); dstHomeOrXmm7 + loadV128IntoLocal + storeXmm7IfSpilledLocal
  (op_simd_int_arith.zig).
- **Continuity-memo**: x86_64-only asymmetry. **REMAINING 4 sites (same both-stages-internal class)**: emitI8x16Swizzle
  (PSHUFB idx-ctrl) + emitI8x16Shuffle (2-operand PSHUFB), emitI8x16Popcnt (reads src 2× → reload src into a stage
  twice; dst→home/XMM7; XMM7 src-alias stash only when dst home), emitI64x2Mul (XMM14+XMM15+XMM7-rhs-stash). Apply the
  just-in-time reload + the new file-local helpers (op_simd_int_arith.zig already has dstHomeOrXmm7/loadV128IntoLocal/
  storeXmm7IfSpilledLocal; swizzle/shuffle are in op_simd_int_cmp_lane.zig → use its resolveOrLoadV128). Fixture =
  live-stack 13-v128-pressure trick (OR/drop chain). **GOTCHA: verify values via wasmtime `--invoke f -W gc=y
  -W function-references=y <f>.wasm` + double-check the SIMD opcode byte.** REJECT a global 3rd-stage-XMM pool cut.
- **Exit-condition**: every a–g sub-category's operand forced to spill flows through its op on BOTH arches; zero
  bare resolveGpr/resolveFp/resolveXmm SPILL-EXEMPT sites remain (except the structural 3-V-reg select/bitselect).

## RESUME POINTER (2026-06-18) — for a fresh session

0. **ADR-0195 guest↔guest async — CAMPAIGN COMPLETE** (D-335 closed; detail in git + ADR-0195; residuals D-463
   CLOSED / D-464 future-bucket). **D-461 v128-DST-spill arc COMPLETE both arches** (FP replace_lane @4acd24152).
1. **Active bundle = D-034** (above): through @b870f146a — 15 sites DONE. **REMAINING = 4 x86_64 int-arith (g) sites**
   (same both-stages-internal class, just-in-time-reload technique): emitI8x16Swizzle, emitI8x16Shuffle (op_simd_int_
   cmp_lane.zig), emitI8x16Popcnt, emitI64x2Mul (op_simd_int_arith.zig). Drive op-by-op TDD (live-stack v128-pressure
   fixture, RED→GREEN both arches; verify values via wasmtime GC flags). The file-local helpers already exist in both
   files. This closes the whole D-034 (g) sub-arc → bundle exit-condition met.
2. **Audit DONE 2026-06-18 (CLEAN)** — `audit_scaffolding` 0 block/0 soon (J.3 chronic debt); fuzz 0 crashes.
3. **D-460 v128-GC JIT emit DONE both arches** (@3d8be3c00/@8137c7268/@5292569e0; 6 runI32Export fixtures = the
   authoritative JIT verification). Only an optional edge fixture remains (low value). Consumer-gated, do NOT grind:
   D-464(2) broader async + D-305 rare CM shapes (those NEED a consumer; D-034 does NOT, hence it is driven).
4. **D-461 v128-DST-spill arc — FULLY COMPLETE both arches** (FP replace_lane @4acd24152; v128-on-JIT block split
   to `runner_v128_jit_test.zig`, ADR-0198). D-461 → `note`. Its scalar-operand sibling = the D-034 active bundle.

## Recently closed arcs (detail in ADRs/git/debt — one-liners)

- **D-305 first milestone** (@4cceeb1e, ADR-0196): cross-component STRING marshalling; `component_graph.zig`
  two-level instantiation + boundary trampoline via `canon.CanonContext`. Common shapes now ALL done (see top).

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
- **Debt**: 62 entries; `now`-class = **D-034** (GPR/FP-scalar spill cohort = active bundle; D-461 v128 arc DONE →
  `note`). D-460 v128-GC emit DONE both arches. D-335 → `note` (ADR-0195 scheduler DONE).
  Rest front-tagged (future-bucket/parked); D-462 feature-separation = user-gated.
- **Realworld corpus**: 56 fixtures (c/cpp/emcc/go/tinygo/rust/zig), interp 56/0; JIT run-stage opt-in.
- **Tag**: `v2.0.0-alpha.3` tag-only (no Release → Latest stays v1.11.0), USER-ONLY.

## Key refs

- [`flake.nix`](../flake.nix) `devShells.gen` / `.#gen-wasip3` — fixture toolchains. [`docs/zig_api_design.md`](../docs/zig_api_design.md).
- ADRs: **0156** (NO autonomous release) · **0153** (rework) · **0187-0191** (CM-async) · **0185** (x86_64 EH) ·
  **0099** (file-size caps) · **0126** (iso-recursive canonical equality).
- lessons INDEX: `.dev/lessons/INDEX.md` (keyword index for Step 0.4).
