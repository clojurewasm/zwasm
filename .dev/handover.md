# Session handover

> ≤ 100 lines. Canonical fresh-session entry point. Framing:
> [`handover_doc_discipline.md`](../.claude/rules/handover_doc_discipline.md).

## Current state

- **Phase**: **10 IN-PROGRESS — CLOSE-ELIGIBLE** (Phase 9 = DONE 2026-05-24).
- **HEAD**: `9585df11` (cyc215). **I3 cross-feature edge fixtures landed**:
  `test/edge_cases/p10/cross/` now has `call_ref_to_memory64` (→ 42) +
  `return_call_to_memory64` (→ 99) — both stress a Wasm-3.0 proposal pair
  (funcref-call / tail-call × memory64) through the JIT runner, locking R15/
  runtime_ptr survival into a memory64-addressing callee. Both green on Mac;
  WAT assembled with wasm-tools parse. 10.P I3 SKIP → now populated.
- **D-209 VERIFIED green on ubuntu** this cycle (Step 0.7: `OK (HEAD=fd2fd267)`,
  wast_runner 1158/1158) — the memory64 memarg-offset width fix holds on x86_64.
  D-208 (cyc213) + D-209 (cyc214) both fixed + ubuntu-verified.
- **10.P close-invariants (as of cyc214): 16 PASS / 8 SKIP / 0 FAIL** → close-eligible.
  I3 now populated (was a SKIP); remaining SKIPs: I14 (EH wasm.h c_api tag accessors,
  AUTONOMOUS), I5/I11/I16/I20/I23 (deferred-to-close-cycle), I21 (realworld tool-gated).
- **Step 0.7 on resume**: cyc215 is a TEST-ONLY change (2 fixtures) → ubuntu kicked on
  `9585df11`. VERIFY (`tail -3 /tmp/ubuntu.log`): the 2 cross fixtures pass on x86_64
  (call_ref/return_call × memory64). FAIL ⟹ an x86_64 interaction bug → investigate
  (revert is fixture-only, low-risk).

## Active task — I3 cont'd: EH × call_ref cross fixture (+ a 2nd pair)  **NEXT**

Phase-10-close-prep, autonomous; continue broadening `test/edge_cases/p10/cross/`.
Next pair: **EH × function-references** — a `try_table` catching a tag whose body does a
`call_ref` to a function that `throw`s the tag → caught → returns a known i32 (stresses EH
unwind across a call_ref boundary). Then a 2nd pair (multi-memory × tail-call OR GC × call_ref).
Cross-feature interactions are where realworld bugs hide (D-209 surfaced this way). Mirror the
edge-runner `.wat`/`.wasm`/`.expect` convention (`runI32Export` JIT; assemble with
`wasm-tools parse`). Smallest red: the EH×call_ref fixture, run → expected i32.
Deferred: I14 EH c_api tag accessors (impl, likely close-cycle scope); D-206 cross-module
TC (multi-module JIT harness first); 10.G GC JIT (extreme).

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
