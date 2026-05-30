# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS — CLOSE-ELIGIBLE** (Phase 9 = DONE 2026-05-24).
- **HEAD**: `0b8d2a0b` (cyc216). **I3 cross fixtures = 4** + **edge-runner caching fix**.
  `test/edge_cases/p10/cross/` now: `call_ref_to_memory64`→42, `return_call_to_memory64`→99,
  `eh_call_ref_catch`→77 (EH unwind across a call_ref boundary), `eh_memory64_catch`→55
  (EH × memory64 in one frame). All green on Mac via the JIT runner (assembled with
  wasm-tools parse). **build.zig fix**: the edge/realworld run steps passed their corpus
  dir via `addArg(string)` (untracked input) → zig cached the run-artifact + SKIPPED
  re-running on fixture-only changes → FALSE coverage (cyc215's cross fixtures were never
  actually run by the gate, Mac AND ubuntu). Fixed with `has_side_effects = true` on all
  4 run_edge_* steps. Lesson `2026-05-30-edge-runner-fixture-cache-false-coverage`.
- **D-209 VERIFIED green on ubuntu** (cyc215 Step 0.7: `OK (HEAD=fd2fd267)`, wast_runner
  1158/1158). D-208 (cyc213) + D-209 (cyc214) both fixed + ubuntu-verified.
- **10.P close-invariants (cyc214): 16 PASS / 8 SKIP / 0 FAIL** → close-eligible. I3 now
  populated; remaining SKIPs: I14 (EH wasm.h c_api tag accessors, AUTONOMOUS), I5/I11/I16/
  I20/I23 (deferred-to-close-cycle), I21 (realworld tool-gated).
- **Step 0.7 on resume**: cyc216 changed build.zig (run-step flags forcing re-run) +
  added 2 fixtures → ubuntu kicked on `0b8d2a0b`. This is the FIRST real x86_64 run of all
  4 cross fixtures (the has_side_effects fix un-caches them). VERIFY (`tail /tmp/ubuntu.log`):
  the 4 cross fixtures pass on x86_64. FAIL ⟹ an x86_64 interaction bug → investigate
  (fixture/build-only change, low-risk revert).

## Active task — I14: EH wasm.h c_api tag accessors  **NEXT**

Cross-feature coverage (I3) is now solid (4 fixtures across the cleanly-JIT-able pairs;
remaining clean combos hit the GC-JIT / multi-memory-JIT gaps, not worth forcing). Next
autonomous close-prep: **I14** — implement the EH-related `wasm.h` C-API tag accessors
(10.E c_api scope; the EH *runtime* is done, D-192 resolved — this is the public C-ABI
surface). Step 0 survey first: enumerate which `wasm_tag_*` / exception accessors `wasm.h`
declares vs what `src/api/` implements, and scope whether it's a clean chunk or ADR-grade.
If substantial/ADR-grade → reconsider (the close is a user touchpoint; remaining autonomous
work is thinning). Deferred: D-206 cross-module TC (multi-module JIT harness first); 10.G
GC JIT (extreme).

## §10 close map

Spec-corpus rows (10.G/10.M/10.E/10.TC/10.R) mature; 10.P now close-eligible (0 FAIL).
- **realworld/p10**: clang_musttail DONE (cyc201) + clang_wasm64 DONE (cyc214, JIT
  result-checked). emscripten/dart/ocaml/hoot TOOL-GATED (no toolchain).
- **gc .17** funcref-RTT (D-198) — deep defer. **funcrefs** 34/39 — 5 gated.
- **10.P close = user touchpoint** (see Open questions).

## Spec runner observable (cyc190, DIRECT binary run)

```
[memory64           ] return=337 (all pass)    [tail-call] return=71 (all pass)
[exception-handling ] 34/34 ✅ FULLY GREEN     [function-references] return=34/39
[gc                 ] return=349/407 trap=96/100 invalid=60/60 ✅ malformed=1/1 skip=20
[multi-memory       ] return=407/407 trap=244/244  ← cyc188 ALL-GREEN
```
> gc residual: return=1 + trap=4 = type-subtyping.30/.48/.50. Use `--fail-detail`.

## Open questions / blockers

- D-197: validate-error surfacing ad-hoc via cyc143 op-probe; permanent diag = D-197 tail.
- D-206: cross-module tail-call JIT (multi-module harness-gated). D-209: > 4 GiB memory64
  offset (payload u32) deferred.
- **User touchpoint (2026-05-30)**: **Phase 10 is NOW close-eligible (10.P 0 FAIL)** — the
  last close-blocker (D-208) + the realworld memory64 gap (D-209) are cleared. The funcref/
  tail-call JIT matrix + memory64 realworld are DONE both arches. A user check-in on
  **formally closing Phase 10 (→ Phase 11) vs continuing JIT-completeness** (D-206
  cross-module TC, 10.G GC JIT — both NOT close-required; interp covers the corpus) is
  high-value here. NOT a stop — loop continues autonomously on I3 (close-prep); re-arm holds.

## Key refs

- ADR-0111 (memory64 D4/D5); ADR-0114 (EH); ADR-0115/0116/0121 (GC); ADR-0112 (tail-call).
- `.dev/lessons/2026-05-30-jit-funcref-tail-call-codegen-recipe.md` (D-208) +
  `2026-05-30-clang-wasm-realworld-toolchain-recipe.md` (clang musttail + wasm64).
- ROADMAP §10; `.dev/phase_log/phase10.md`; `scripts/check_phase10_close_invariants.sh`.
