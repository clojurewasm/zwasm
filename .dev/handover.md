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

**D-034 SIMD spill-completeness arc — CLOSED 2026-06-19 @411dd1e14 (bundle exit-condition met).** All scalar
sub-categories (a–g) + the full 18-site x86_64 v128-operand (g) sub-arc are spill-aware on both arches; the only
remaining bare-resolve sites are the structural emitV128Select val2 (3-V-reg-vs-2-stage) + emitI64x2Mul's
byte-identical all-reg fast path. Detail + per-op SHAs in the D-034 debt row (now `note`) + git. Low-pri follow-up:
consolidate the duplicated spill helpers into a shared op_simd.zig pub set.

## RESUME POINTER (2026-06-19) — for a fresh session

0. **ADR-0195 guest↔guest async — CAMPAIGN COMPLETE** (D-335 closed; detail in git + ADR-0195; residuals D-463
   CLOSED / D-464 future-bucket). **D-461 v128-DST-spill arc COMPLETE both arches** (FP replace_lane @4acd24152).
1. **D-034 SIMD spill arc CLOSED @411dd1e14** — no active bundle; ZERO `now`-class debt; **D-460 v128-GC arc ALSO
   COMPLETE** (array.copy was already done @5292569e0 — the 2026-06-19 sweep misread a stale "REMAINING" line; a
   confirm-before-implement survey caught it, D-460 → `note`, jit_abi.zig docstring corrected). The debt is at the
   **exhaustively-validated 完成形 plateau** (2026-06-19) — all 4 dimensions at the bar; every Phase-16 activity walked
   + GREEN (so the next resume need NOT re-walk these): (a) debt-coherence audit @9bd551958 (zero `now`-debt); (b)
   spill arc ubuntu+windows verified, baseline @66976f436; (c) memory-safety fuzz smoke 0-crash over post-D-034
   codegen; (d) dogfooding realworld JIT compile-pass 56/56; (e) **surface audits ALL THREE done & clean** — C-API
   @a6c82e6 (complete vs standard wasm-c-api), Zig-API + CLI @ae032aab (structurally complete, no help-vs-code
   mismatch); the only findings across all 3 were stale doc-comments, all fixed (@3c84ae3b3, @ce4224afc). JUDGED
   NOT-WORTH-DOING per Simplicity-First (do NOT re-litigate): D-294-R2 (a new TrapKind for a conformance-neutral
   message nicety = over-engineering on an already-spec-correct trap); the helper-consolidation (low-ROI big refactor
   re-churning the whole verified v128-spill arc for a benign internal DRY smell).
   **D-331(B) go_regex SlotOverflow — CLOSED 2026-06-19 @adb7b99a** (arm64 large-frame spill-offset overflow >
   W-form imm12 cap 16380; siblings routed through frame{Ldr,Str}{Gpr,Fp}; go_regex diff-jit MATCHES wasmtime
   94 B; detail in D-331 row + lesson `2026-06-19-arm64-large-frame-spill-offset`).
   **D-305 cross-component 3-PARAM ARITY — DONE @db79e7df**
   (BoundarySig3 + boundaryTrampoline3 pass-through; fixture arity3_graph; comp-assert 164/0). NEXT FRONT (pick
   any; all drivable now): (1) **D-466 (now)** — failed-`instantiateGraph` cleanup DOUBLE-FREE (surfaced by the
   arity3 RED run; latent — reproduce via an unsupported-boundary fixture, audit errdefer-vs-graph-owned). Quick
   memory-safety win. (2) **D-305 follow-ons** — 4..7 flat-scalar arities (same recipe as 3); then aggregate
   record/result params (NOMINAL-type fixtures: B exports type + A imports it; flat record = pass-through but a
   wasm-tools validate snag remains; non-flat → canon.store/load, already built). (3) **D-331(A) go-runtime
   poll_oneoff miscompile** — build the **memory-divergence diff** FIRST (~120-200 LOC, NOT ADR-gated: hash
   mem+globals at the shared host-call boundary jit_dispatch.zig:352/:65 + interp mvp.zig:392, diff JIT vs interp;
   approach recorded in D-331 (A)); the per-func interp-fallback knob is ADR-gated + ~600-1000 LOC, defer.
   **D-330 c_sha256 `\n` is PROVABLY-BLOCKED (bucket-2, survey-confirmed)**: genuine constraint conflict
   (block-result liveness extension fixes c_sha256 but regresses br_table/labels), cosmetic (1 byte, values+interp
   correct), row says do-NOT-re-run the blanket fix — do not drive. D-464 broader async stays consumer-gated.
2. **Audit DONE 2026-06-18 (CLEAN)** — `audit_scaffolding` 0 block/0 soon (J.3 chronic debt); fuzz 0 crashes.
3. **D-460 v128-GC arc COMPLETE both arches** — struct/array get/set/new_fixed/new_default emit (@3d8be3c00/
   @8137c7268/@5292569e0) + array.copy (@5292569e0, jit_abi.zig:1049 `ai.element.size`); 7 runI32Export fixtures.
   D-460 → `note`. Consumer-gated, do NOT grind: D-464(2) broader async + D-305 rare CM shapes (need a consumer).
4. **D-461 v128-DST-spill arc — FULLY COMPLETE both arches** (FP replace_lane @4acd24152; ADR-0198). D-461 → `note`.
   Its scalar-operand sibling D-034 arc is now also CLOSED @411dd1e14 (the entire v128 spill story is complete).

## Recently closed arcs (detail in ADRs/git/debt — one-liners)

- **D-305 first milestone** (@4cceeb1e, ADR-0196): cross-component STRING marshalling; `component_graph.zig`
  two-level instantiation + boundary trampoline via `canon.CanonContext`. Common shapes now ALL done (see top).

## Closed/paused (detail in git + debt.yaml)

- **doc-inventory freshening DONE** (`42441634` README + ADR-0193 P4 doc-sync): reader-facing surfaces clean
  (C-API 293/293, component 158/0/0, Wasm 2.0 skip-impl==0, 3.0 all-9-proposals, version anchors retired).
- **ADR-0192 wasmtime differential campaign — paused**: goal met (9 real engine bugs fixed via wasmtime
  misc_testsuite + 6 SIMD via D-457). Residuals: **`D-460`** v128-GC COMPLETE both arches (`note`); **`D-209`**
  memory64 >4 GiB offset, **D-456** host-import fixtures (parked). Harness `scripts/wasmtime_misc_*.sh`.

**Closed campaigns (detail in git/lessons)**: prior 4-front async-maturity (2026-06-16) — ② wasmtime async .wast
TIER-1 (`afcf889a`/`05b35c28`; D-446/447 deferred), ① wasip3 conformance (7 real-rust fixtures, `.#gen-wasip3`),
④ perf (ROI-rejected single-pass ceiling, D-450), ③ real-world GC corpus (6 engine bugs FIXED: D-451-453/9064faa5/
480809af/9ec68a75/79742cb4; 4 GC edge fixtures; real Hoot execution → D-454). **WASI 0.3/Preview-3 core DONE**
(D-335; ADR-0187-0191). validator.zig at 3449/3450 cap — NEXT validator edit MUST extract per the file's marker plan.

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
